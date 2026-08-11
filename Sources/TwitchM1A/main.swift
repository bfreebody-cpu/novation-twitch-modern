import Foundation
import IOKit
import TwitchProbeCore
import USBHostShim

enum M1SessionMode: String {
    case m1a = "m1a"
    case characterize = "m1b-characterize"
    case sustained = "m1b-sustained"
    case disconnect = "m1b-disconnect"
    case reconnectCheck = "m1b-reconnect-check"
    case m2Bridge = "m2-bridge"
    case m2Verify = "m2-verify"
    case m4LEDTest = "m4-led-test"
    case m4Bridge = "m4-bridge"
    case m4Verify = "m4-verify"

    var milestone: String {
        switch self {
        case .m1a: "M1a"
        case .characterize, .sustained, .disconnect, .reconnectCheck: "M1b"
        case .m2Bridge, .m2Verify: "M2"
        case .m4LEDTest, .m4Bridge, .m4Verify: "M4"
        }
    }
    var captureSuffix: String { "twitch-\(rawValue)" }
    var defaultDuration: Int {
        switch self {
        case .m1a: 180
        case .characterize: 1_200
        case .sustained: 300
        case .disconnect: 300
        case .reconnectCheck: 45
        case .m2Bridge: 1_800
        case .m2Verify: 300
        case .m4LEDTest: 300
        case .m4Bridge: 1_800
        case .m4Verify: 600
        }
    }
}

let arguments = CommandLine.arguments
let mode: M1SessionMode = {
    guard let index = arguments.firstIndex(of: "--mode"), index + 1 < arguments.count else { return .m1a }
    guard let parsed = M1SessionMode(rawValue: arguments[index + 1]) else {
        FileHandle.standardError.write(Data("Invalid --mode. Use m1a, m1b-characterize, m1b-sustained, m1b-disconnect, m1b-reconnect-check, m2-bridge, m2-verify, m4-led-test, m4-bridge, or m4-verify.\n".utf8))
        exit(EXIT_FAILURE)
    }
    return parsed
}()
let duration: Int = {
    guard let index = arguments.firstIndex(of: "--duration"), index + 1 < arguments.count,
          let value = Int(arguments[index + 1]), (10...1_800).contains(value) else {
        return mode.defaultDuration
    }
    return value
}()
let maximumTransfers = mode == .m1a ? 10_000 : 100_000
let maximumPayloadBytes = mode == .m1a ? 1_048_576 : 8_388_608
let maximumSysExBytes = 1_024
let characterizationStartStep: Int = {
    guard let index = arguments.firstIndex(of: "--start-step"), index + 1 < arguments.count,
          let value = Int(arguments[index + 1]), (1...11).contains(value) else { return 1 }
    return value
}()
let operatorNotes: [String] = arguments.enumerated().compactMap { index, argument in
    argument == "--operator-note" && index + 1 < arguments.count ? arguments[index + 1] : nil
}
let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let runStart = DispatchTime.now().uptimeNanoseconds
let startedAt = M1Discovery.wallTime()

do {
    let recorder = try RunRecorder(
        repositoryRoot: repositoryRoot, maximumTransfers: maximumTransfers,
        maximumPayloadBytes: maximumPayloadBytes, captureSuffix: mode.captureSuffix
    )
    recorder.note("\(mode.milestone) started in \(mode.rawValue) mode; exact match required for USB VID 0x1235 PID 0x0018")
    for note in operatorNotes { recorder.note("operator observation: \(note)") }

    let baseline = try M1Discovery.baseline(runStart: runStart)
    guard baseline.state.device.properties["kUSBCurrentConfiguration"] == "1" else {
        throw M1Error.invalidEvidence("device is not in measured configuration 1")
    }
    guard let configuration = baseline.configurations.first else {
        throw M1Error.invalidEvidence("configuration descriptor missing")
    }
    let endpoint = try M1Discovery.endpointIN(configuration: configuration)
    let isM4 = mode == .m4LEDTest || mode == .m4Bridge || mode == .m4Verify
    let outputEndpoint = isM4 ? try M1Discovery.endpointOUT(configuration: configuration) : nil
    recorder.note(
        "baseline: configuration 1; interface 0 alt 0; interface 1 alt 0; controller IN 0x84 interrupt max packet \(endpoint.maximumPacketPayloadBytes) interval \(endpoint.interval)"
    )
    recorder.note("baseline complete; no endpoint traffic submitted")

    recorder.note("activation: performing only interface 0 alternate 1 -> alternate 0")
    let activation = try TwitchActivation.perform(runStart: runStart)
    for observation in activation {
        recorder.note("\(observation.operation): success=\(observation.success) observedAlternate=\(observation.observedAlternate.map(String.init) ?? "unknown")")
    }
    let afterActivation = try M1Discovery.snapshot(
        phase: "after-activation-before-controller-open", runStart: runStart
    )
    guard try M1Discovery.currentAlternate(interfaceNumber: 0) == 0 else {
        throw M1Error.invalidEvidence("interface 0 registry state was not restored to alternate 0")
    }

    let coreMIDIBridge: CoreMIDIVirtualSource?
    if mode == .m2Bridge || mode == .m2Verify || mode == .m4Bridge || mode == .m4Verify {
        let monitorURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("twitch-midi-monitor")
        let bridge = try CoreMIDIVirtualSource(
            runStartNanoseconds: runStart, verificationEnabled: mode == .m2Verify,
            monitorExecutableURL: mode == .m2Verify ? monitorURL : nil
        )
        guard bridge.registration.foundByEndpoint,
              bridge.registration.enumeratedName == CoreMIDIVirtualSource.sourceName else {
            bridge.close()
            throw M1Error.invalidEvidence("Core MIDI virtual source was created but could not be enumerated by endpoint and name")
        }
        coreMIDIBridge = bridge
        recorder.note(
            "Core MIDI virtual source created and enumerated: \(CoreMIDIVirtualSource.sourceName), MIDI 1.0 protocol"
        )
    } else {
        coreMIDIBridge = nil
    }

    let eventSink: (@Sendable ([DecodedMIDIEvent]) -> Void)?
    if let bridge = coreMIDIBridge {
        eventSink = { [bridge] events in bridge.publish(events) }
    } else {
        eventSink = nil
    }
    let listener = ControllerListener(
        endpoint: endpoint, runStart: runStart, recorder: recorder,
        maximumSysExBytes: maximumSysExBytes,
        outputEndpoint: outputEndpoint,
        eventSink: eventSink
    )
    try listener.start()

    let coreMIDIDestination: CoreMIDIVirtualDestination?
    if mode == .m4Bridge || mode == .m4Verify {
        let destination = try CoreMIDIVirtualDestination { [listener] messages in
            try listener.sendOutput(messages)
        }
        guard destination.registration.foundByEndpoint,
              destination.registration.enumeratedName == CoreMIDIVirtualDestination.destinationName else {
            destination.close()
            listener.requestStop(reason: "Core MIDI destination registration failed")
            _ = listener.wait()
            coreMIDIBridge?.close()
            throw M1Error.invalidEvidence(
                "Core MIDI virtual destination was created but could not be enumerated by endpoint and name"
            )
        }
        coreMIDIDestination = destination
        recorder.note(
            "Core MIDI virtual destination created and enumerated: \(CoreMIDIVirtualDestination.destinationName), MIDI 1.0 protocol"
        )
    } else {
        coreMIDIDestination = nil
    }

    let signalQueue = DispatchQueue(label: "org.twitch-modern.m1.signals")
    let signalSource: DispatchSourceRead
    do {
        signalSource = try installSignalSource(listener: listener, queue: signalQueue)
    } catch {
        listener.requestStop(reason: "signal setup failed")
        _ = listener.wait()
        coreMIDIBridge?.close()
        throw error
    }

    var interactive: M1InteractiveCoordinator?
    var m2Interactive: M2InteractiveCoordinator?
    switch mode {
    case .m1a:
        print("""

        Twitch M1a input is listening on endpoint 0x84. Perform PLAY, CUE, crossfader,
        one encoder in both directions, and a left-touchstrip gesture. Press Ctrl-C
        when complete; the listener is bounded to \(duration) seconds.

        """)
    case .characterize:
        let coordinator = M1InteractiveCoordinator(
            recorder: recorder, listener: listener, runStart: runStart
        )
        interactive = coordinator
        print("\nM1b basic-mode characterization is listening on endpoint 0x84.\n")
        coordinator.start(atOneBasedStep: characterizationStartStep)
    case .sustained:
        print("""

        M1b sustained-input test is listening for \(duration) seconds (target: 300).
        Manipulate controls normally and intermittently. Do not unplug during this run.
        Traffic is physical input only; no traffic will be generated by the program.

        """)
    case .disconnect:
        print("""

        M1b disconnect test is listening. Move one control to establish input, then
        physically unplug the Twitch. After safe removal is detected, this process will
        prompt for reconnection and perform discovery only; it will not reopen endpoints.

        """)
    case .reconnectCheck:
        print("""

        M1b process-restart recovery check is listening for \(duration) seconds.
        Operate PLAY, one encoder and one fader to confirm the reconnected Twitch works.

        """)
    case .m2Bridge:
        print("""

        Twitch M2 bridge is running. Core MIDI virtual source:
          \(CoreMIDIVirtualSource.sourceName)

        Twitch controller input is being forwarded transparently to MIDI applications.
        Press Ctrl-C to stop; the bridge is bounded to \(duration) seconds.

        """)
    case .m2Verify:
        guard let bridge = coreMIDIBridge else {
            throw M1Error.invalidEvidence("M2 verification started without a Core MIDI source")
        }
        let coordinator = M2InteractiveCoordinator(
            recorder: recorder, listener: listener, bridge: bridge
        )
        m2Interactive = coordinator
        print("""

        Twitch M2 verification is running. Core MIDI virtual source:
          \(CoreMIDIVirtualSource.sourceName)

        Each step compares USB-decoded events, events published to Core MIDI, and events
        received by a separate-process Core MIDI 1.0 verification consumer.

        """)
        coordinator.start()
    case .m4LEDTest:
        print("""

        Twitch M4 Stage A is ready. This test sends only the documented basic-mode
        left PLAY LED message on controller OUT endpoint 0x03. It does not create a
        Core MIDI destination and does not use advanced mode.

        Press Return to illuminate left PLAY full green.
        """)
        fflush(stdout)
        _ = readLine()
        try listener.sendOutput([[0x97, 23, 127]])
        print("Left PLAY on command queued. Confirm the physical result, then press Return to extinguish it.")
        fflush(stdout)
        _ = readLine()
        try listener.sendOutput([[0x97, 23, 0]])
        print("Left PLAY off command queued. Press Return after confirming the result.")
        fflush(stdout)
        _ = readLine()
        listener.requestStop(reason: "M4 Stage A operator completed documented LED test")
    case .m4Bridge, .m4Verify:
        print("""

        Twitch M4 bidirectional bridge is running.
          Core MIDI source:      \(CoreMIDIVirtualSource.sourceName)
          Core MIDI destination: \(CoreMIDIVirtualDestination.destinationName)

        Input remains on endpoint 0x84. Documented basic-mode LED output is accepted
        on endpoint 0x03 through a bounded queue. Advanced mode is disabled.
        Press Ctrl-C to stop; the bridge is bounded to \(duration) seconds.

        """)
    }
    fflush(stdout)

    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(duration)) {
        listener.requestStop(reason: "bounded duration of \(duration) seconds elapsed")
    }
    let result = listener.wait()
    signalSource.cancel()
    signalQueue.sync {}
    TwitchCloseSignalPipe()

    var reconnectObservation: M1ReconnectObservation?
    if mode == .disconnect {
        let handled = result.shutdownReason == "device disconnected" || result.shutdownReason == "input transfer failed"
        if handled {
            recorder.note("removal handled; reconnect the Twitch now (discovery-only wait, no endpoint reopen)")
            print("\nThe removal path has completed safely. Please reconnect the Twitch now.\n")
            fflush(stdout)
            let requested = M1Discovery.wallTime()
            do {
                let service = try M1Discovery.waitForReconnectedDevice(
                    previousRegistryEntryID: baseline.state.device.registryEntryID,
                    previousSessionID: baseline.state.device.properties["sessionID"],
                    timeoutSeconds: 120
                )
                IOObjectRelease(service)
                reconnectObservation = M1ReconnectObservation(
                    disconnectHandled: true, disconnectReason: result.shutdownReason,
                    reconnectRequestedAtUTC: requested, reconnectedDeviceDiscovered: true,
                    reconnectedAtUTC: M1Discovery.wallTime(), waitSeconds: 120,
                    policy: "reconnection discovered in-process; endpoint resume intentionally requires a clean process restart in M1b",
                    error: nil
                )
                recorder.note("reconnected exact Twitch discovered; endpoint resume deferred to process restart")
            } catch {
                reconnectObservation = M1ReconnectObservation(
                    disconnectHandled: true, disconnectReason: result.shutdownReason,
                    reconnectRequestedAtUTC: requested, reconnectedDeviceDiscovered: false,
                    reconnectedAtUTC: nil, waitSeconds: 120,
                    policy: "process restart required", error: String(describing: error)
                )
                recorder.note("bounded reconnect discovery failed: \(error)")
            }
        } else {
            reconnectObservation = M1ReconnectObservation(
                disconnectHandled: false, disconnectReason: result.shutdownReason,
                reconnectRequestedAtUTC: nil, reconnectedDeviceDiscovered: false,
                reconnectedAtUTC: nil, waitSeconds: 0,
                policy: "disconnect was not observed", error: "run ended before physical removal was detected"
            )
        }
    }

    let afterState = try? M1Discovery.snapshot(phase: "after-clean-shutdown", runStart: runStart)
    let limits = M1Limits(
        endpointMaximumPacketSize: Int(endpoint.maximumPacketPayloadBytes), concurrentReads: 1,
        maximumTransfers: maximumTransfers, maximumPayloadBytesLogged: maximumPayloadBytes,
        maximumSysExBytes: maximumSysExBytes, durationSeconds: duration
    )
    let metrics = M1Analysis.metrics(result: result)
    if isM4 {
        let destinationBoundary = coreMIDIDestination?.snapshot()
        let outputCapture = M4Capture(
            schemaVersion: 1, milestone: "M4", mode: mode.rawValue,
            startedAtUTC: startedAt, endedAtUTC: M1Discovery.wallTime(),
            sourceRegistration: coreMIDIBridge?.registration,
            destinationRegistration: coreMIDIDestination?.registration,
            coreMIDIOutputEvents: destinationBoundary?.events ?? [],
            coreMIDIErrors: destinationBoundary?.errors ?? [],
            usbInputTransferCount: result.rawTransfers.count,
            decodedInputEventCount: result.midiEvents.count,
            usbOutputTransfers: recorder.outputResults(),
            outputQueueAtShutdown: listener.capturedOutputSnapshot(),
            shutdownReason: result.shutdownReason,
            inputAbortResult: result.abortResult,
            restorationResult: result.restorationResult,
            stateBefore: baseline.state, stateAfter: afterState,
            activation: activation, operatorNotes: operatorNotes,
            safetyStatement: [
                "Controller output restricted to interface 1 alternate 0 interrupt OUT endpoint 0x03",
                "Maximum output packet size derived from descriptor (\(outputEndpoint?.maximumPacketPayloadBytes ?? 0) bytes)",
                "Only documented basic-mode MIDI output allowlist accepted",
                "No advanced-mode, global diagnostic, SysEx, vendor-specific, reset, or configuration request",
                "No transfer to audio endpoints 0x01 or 0x82 and no Core Audio action",
            ]
        )
        try M1Output.writeRawEvidence(baseline: baseline, directory: recorder.directory)
        try M4Output.write(outputCapture, directory: recorder.directory)
        coreMIDIDestination?.close()
        coreMIDIBridge?.close()
    } else if let bridge = coreMIDIBridge {
        bridge.waitForMonitorDrain()
        let boundary = bridge.snapshot()
        let comparison = M2Output.comparison(
            published: boundary.published, monitored: boundary.monitored,
            verification: bridge.verificationEnabled
        )
        let capture = M2Capture(
            schemaVersion: 1, milestone: "M2", startedAtUTC: startedAt,
            endedAtUTC: M1Discovery.wallTime(), sourceCreationSucceeded: true,
            sourceRegistration: bridge.registration,
            sourceName: CoreMIDIVirtualSource.sourceName, protocolName: "MIDI 1.0 UMP",
            coreMIDIAPI: [
                "MIDIClientCreateWithBlock", "MIDISourceCreateWithProtocol",
                "MIDIReceivedEventList",
                "external MIDIInputPortCreateWithProtocol MIDI 1.0 verifier",
            ],
            verificationEnabled: bridge.verificationEnabled,
            verificationSteps: m2Interactive?.steps() ?? [],
            publishedEvents: boundary.published, monitoredEvents: boundary.monitored,
            coreMIDIErrors: boundary.errors, usbEventCount: result.midiEvents.count,
            publishableUSBEventCount: result.midiEvents.filter { $0.kind != "parser-warning" }.count,
            publishedEventCount: boundary.published.count,
            monitoredEventCount: boundary.monitored.count,
            exactPublishedToMonitoredMatch: comparison.0,
            firstPublishedToMonitoredMismatch: comparison.1,
            shutdownReason: result.shutdownReason, abortResult: result.abortResult,
            restorationResult: result.restorationResult,
            parserIncompleteStateAtShutdown: result.parserIncompleteState,
            stateBefore: baseline.state, stateAfter: afterState, activation: activation,
            safetyStatement: [
                "No controller OUT transfer or endpoint 0x03 open",
                "No transfer to audio endpoints 0x01 or 0x82",
                "No vendor-specific request, reset, or configuration change",
                "No MIDI sent to the Twitch; no LED command or advanced-mode request",
                "No Core MIDI destination, Core Audio, Mixxx, DriverKit, or legacy driver action",
            ]
        )
        try M1Output.writeRawEvidence(baseline: baseline, directory: recorder.directory)
        try M2Output.write(capture, directory: recorder.directory)
        bridge.close()
    } else {
        let capture = M1Capture(
            schemaVersion: 2, milestone: mode.milestone, startedAtUTC: startedAt,
            endedAtUTC: M1Discovery.wallTime(),
            hostOperatingSystem: processOutput("/usr/bin/sw_vers", []),
            hostArchitecture: processOutput("/usr/bin/uname", ["-m"]),
            deviceDescriptor: baseline.device, configurations: baseline.configurations,
            limits: limits, stateBefore: baseline.state, activation: activation,
            stateAfterActivation: afterActivation, rawTransfers: result.rawTransfers,
            midiEvents: result.midiEvents, shutdownReason: result.shutdownReason,
            abortResult: result.abortResult, restorationResult: result.restorationResult,
            parserIncompleteStateAtShutdown: result.parserIncompleteState,
            stateAfter: afterState, testSteps: interactive?.steps() ?? [], metrics: metrics,
            reconnectObservation: reconnectObservation, operatorNotes: operatorNotes,
            safetyStatement: [
                "No controller OUT transfer or endpoint 0x03 open",
                "No transfer to audio endpoints 0x01 or 0x82",
                "No vendor-specific request, reset, or configuration change",
                "No MIDI/LED command, advanced-mode request, or control-position request",
                "No Core MIDI, Core Audio, Mixxx, DriverKit, or legacy driver action",
            ]
        )
        try M1Output.write(capture: capture, baseline: baseline, directory: recorder.directory)
    }
    recorder.note("capture finalized at \(recorder.directory.path)")
    print("\(mode.milestone) session complete: \(recorder.directory.path)")
} catch {
    FileHandle.standardError.write(Data("twitch-m1: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

func processOutput(_ executable: String, _ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    } catch { return "unavailable: \(error)" }
}

func installSignalSource(
    listener: ControllerListener, queue: DispatchQueue
) throws -> DispatchSourceRead {
    let result = TwitchInstallSignalPipe()
    guard result == 0 else {
        throw M1Error.invalidEvidence("could not install signal self-pipe: errno \(result)")
    }
    let source = DispatchSource.makeReadSource(
        fileDescriptor: TwitchSignalReadFileDescriptor(), queue: queue
    )
    source.setEventHandler { [listener] in
        while true {
            let pending = TwitchReadPendingSignal()
            if pending == 0 { break }
            listener.requestStop(reason: pending == 2 ? "Ctrl-C" : "signal \(pending)")
        }
    }
    source.resume()
    return source
}
