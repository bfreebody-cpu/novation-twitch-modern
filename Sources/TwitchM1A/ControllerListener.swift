import Foundation
import IOKit
import IOUSBHost
import TwitchProbeCore
import USBHostShim

private final class InterestRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UInt32) -> Void)?
    func install(_ handler: @escaping (UInt32) -> Void) { lock.withLock { self.handler = handler } }
    func receive(_ message: UInt32) { lock.withLock { handler }?(message) }
}

private final class ReadBuffer: @unchecked Sendable {
    let data: NSMutableData
    init(length: Int) { data = NSMutableData(length: length)! }
}

final class ControllerListener: @unchecked Sendable {
    private let endpoint: EndpointDescriptor
    private let runStart: UInt64
    private let recorder: RunRecorder
    private let parser: MIDIByteStreamParser
    private let outputEndpoint: EndpointDescriptor?
    private let eventSink: (@Sendable ([DecodedMIDIEvent]) -> Void)?
    private let ioQueue = DispatchQueue(label: "org.twitch-modern.m1a.io")
    private let cleanupQueue = DispatchQueue(label: "org.twitch-modern.m1a.cleanup")
    private let stateLock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private let relay = InterestRelay()

    private var interface: IOUSBHostInterface?
    private var pipe: IOUSBHostPipe?
    private var outputPipe: IOUSBHostPipe?
    private var outputWriter: USBControllerOutput?
    private var stopping = false
    private var sequence = 0
    private var result: M1RunResult?
    private var finalOutputSnapshot: M4OutputQueueSnapshot?

    init(
        endpoint: EndpointDescriptor, runStart: UInt64, recorder: RunRecorder,
        maximumSysExBytes: Int,
        outputEndpoint: EndpointDescriptor? = nil,
        eventSink: (@Sendable ([DecodedMIDIEvent]) -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.runStart = runStart
        self.recorder = recorder
        self.outputEndpoint = outputEndpoint
        self.eventSink = eventSink
        parser = MIDIByteStreamParser(maximumSysExBytes: maximumSysExBytes)
    }

    func start() throws {
        guard try M1Discovery.currentAlternate(interfaceNumber: 1) == 0 else {
            throw M1Error.invalidEvidence("interface 1 is not at measured alternate 0")
        }
        let service = try M1Discovery.copyInterface(number: 1)
        defer { IOObjectRelease(service) }
        let opened = try IOUSBHostInterface(
            __ioService: service, options: [], queue: ioQueue,
            interestHandler: { [relay] _, message, _ in relay.receive(message) }
        )
        guard opened.interfaceDescriptor.pointee.bInterfaceNumber == 1,
              opened.interfaceDescriptor.pointee.bAlternateSetting == 0 else {
            opened.destroy()
            throw M1Error.invalidEvidence("opened interface descriptor is not interface 1 alternate 0")
        }
        let inputPipe = try opened.copyPipe(withAddress: Int(endpoint.address))
        guard inputPipe.endpointAddress == Int(endpoint.address) else {
            opened.destroy()
            throw M1Error.invalidEvidence("copied pipe address does not match endpoint 0x84")
        }
        interface = opened
        pipe = inputPipe
        if let outputEndpoint {
            guard outputEndpoint.address == 0x03,
                  outputEndpoint.direction == "out",
                  outputEndpoint.transferType == "interrupt" else {
                opened.destroy()
                interface = nil
                pipe = nil
                throw M1Error.invalidEvidence("refusing non-controller output endpoint")
            }
            let openedOutputPipe = try opened.copyPipe(withAddress: Int(outputEndpoint.address))
            guard openedOutputPipe.endpointAddress == Int(outputEndpoint.address) else {
                opened.destroy()
                interface = nil
                pipe = nil
                throw M1Error.invalidEvidence("copied output pipe address does not match endpoint 0x03")
            }
            outputPipe = openedOutputPipe
            outputWriter = USBControllerOutput(
                pipe: openedOutputPipe, endpoint: outputEndpoint,
                runStart: runStart, recorder: recorder
            ) { [weak self] reason in
                self?.recorder.note(reason)
                self?.requestStop(reason: "output transfer failed")
            }
            recorder.note(
                "interface 1 alternate 0 interrupt OUT endpoint 0x03 opened; maximum packet \(outputEndpoint.maximumPacketPayloadBytes), bounded queue \(USBControllerOutput.queueCapacity)"
            )
        }
        relay.install { [weak self] message in
            self?.recorder.note(String(format: "IOUSBHost interest message 0x%08x", message))
            // kIOMessageServiceIsTerminated = iokit_common_msg(0x010). The C macro is
            // not imported into Swift because it expands through unsupported macros.
            if message == 0xe0000010 { self?.requestStop(reason: "device disconnected") }
        }
        recorder.note("interface 1 alternate 0 opened; interrupt IN endpoint 0x84 opened read-only")
        submitRead()
    }

    func sendOutput(_ messages: [[UInt8]]) throws {
        guard let outputWriter else { throw USBControllerOutputError.closed }
        try outputWriter.enqueue(messages: messages)
    }

    func outputSnapshot() -> (queued: Int, inFlight: Bool, rejected: Int)? {
        outputWriter?.snapshot()
    }

    func capturedOutputSnapshot() -> M4OutputQueueSnapshot? {
        stateLock.withLock { finalOutputSnapshot }
    }

    func requestStop(reason: String) {
        let shouldStop = stateLock.withLock { () -> Bool in
            if stopping { return false }
            stopping = true
            return true
        }
        guard shouldStop else { return }
        recorder.note("shutdown requested: \(reason)")
        cleanupQueue.async { [self] in cleanup(reason: reason) }
    }

    func wait() -> M1RunResult {
        finished.wait()
        return stateLock.withLock { result! }
    }

    private func submitRead() {
        guard !stateLock.withLock({ stopping }), let pipe else { return }
        let buffer = ReadBuffer(length: Int(endpoint.maximumPacketPayloadBytes))
        do {
            try pipe.enqueueIORequest(with: buffer.data, completionTimeout: 0) { [weak self, buffer] status, count in
                self?.completion(status: status, count: count, buffer: buffer.data)
            }
        } catch {
            recorder.note("enqueue failed: \(error)")
            requestStop(reason: "enqueue failed")
        }
    }

    private func completion(status: IOReturn, count: Int, buffer: NSMutableData) {
        sequence += 1
        let withinLimits = recorder.recordTransfer(
            sequence: sequence, runStart: runStart, endpoint: endpoint.address,
            status: status, bytesTransferred: count, buffer: buffer
        )
        if status == kIOReturnSuccess && count > 0 {
            let payload = [UInt8](Data(bytes: buffer.bytes, count: min(count, buffer.length)))
            let now = DispatchTime.now().uptimeNanoseconds - runStart
            let decoded = parser.consume(payload, monotonicNanoseconds: now, transferSequence: sequence)
            recorder.recordEvents(decoded)
            eventSink?(decoded)
        }
        if !withinLimits {
            requestStop(reason: "capture log limit reached")
        } else if status != kIOReturnSuccess {
            if !stateLock.withLock({ stopping }) { requestStop(reason: "input transfer failed") }
        } else {
            submitRead()
        }
    }

    private func cleanup(reason: String) {
        outputWriter?.stopAccepting()
        if let snapshot = outputWriter?.snapshot() {
            stateLock.withLock {
                finalOutputSnapshot = M4OutputQueueSnapshot(
                    queuedPackets: snapshot.queued,
                    transferInFlight: snapshot.inFlight,
                    rejectedPackets: snapshot.rejected
                )
            }
        }
        var abortResult = "no pipe"
        if let pipe {
            let status = TwitchAbortPipeSynchronously(pipe)
            abortResult = status == kIOReturnSuccess
                ? "synchronous pipe abort succeeded"
                : String(format: "synchronous pipe abort failed: 0x%08x", UInt32(bitPattern: status))
        }
        var outputAbortResult = "no output pipe"
        if let outputPipe {
            let status = TwitchAbortPipeSynchronously(outputPipe)
            outputAbortResult = status == kIOReturnSuccess
                ? "synchronous output pipe abort succeeded"
                : String(format: "synchronous output pipe abort failed: 0x%08x", UInt32(bitPattern: status))
        }
        recorder.note("output shutdown: \(outputAbortResult)")
        outputWriter = nil
        outputPipe = nil
        pipe = nil
        interface?.destroy()
        interface = nil

        let restorationResult: String
        do {
            let current = try M1Discovery.currentAlternate(interfaceNumber: 0)
            if current == 0 {
                restorationResult = "interface 0 already at alternate 0; no SET_INTERFACE issued during shutdown"
            } else {
                let service = try M1Discovery.copyInterface(number: 0)
                defer { IOObjectRelease(service) }
                let interface0 = try IOUSBHostInterface(
                    __ioService: service, options: [], queue: nil, interestHandler: nil
                )
                try interface0.selectAlternateSetting(0)
                let observed = interface0.interfaceDescriptor.pointee.bAlternateSetting
                interface0.destroy()
                restorationResult = "interface 0 required restoration; observed alternate \(observed) afterward"
            }
        } catch {
            restorationResult = "could not verify/restore interface 0 (device may be disconnected): \(error)"
        }
        let (transfers, events) = recorder.results()
        let completed = M1RunResult(
            rawTransfers: transfers, midiEvents: events, shutdownReason: reason,
            abortResult: abortResult, restorationResult: restorationResult,
            parserIncompleteState: parser.incompleteStateDescription()
        )
        stateLock.withLock { result = completed }
        finished.signal()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
