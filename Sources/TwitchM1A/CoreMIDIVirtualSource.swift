import CoreAudio
import CoreMIDI
import Foundation
import TwitchProbeCore

enum M2CoreMIDIError: Error, CustomStringConvertible {
    case status(String, OSStatus)
    case invalidEventList(String)

    var description: String {
        switch self {
        case let .status(operation, status):
            "\(operation) failed with OSStatus \(status) (0x\(String(UInt32(bitPattern: status), radix: 16)))"
        case let .invalidEventList(message): message
        }
    }
}

private final class M2BoundaryEvidence: @unchecked Sendable {
    private let condition = NSCondition()
    private var published: [M2PublishedEvent] = []
    private var monitored: [M2MonitoredEvent] = []
    private var errors: [String] = []
    private var monitorReady = false

    func recordPublished(
        event: DecodedMIDIEvent, hostTime: UInt64, words: [UInt32], status: OSStatus
    ) {
        condition.lock()
        published.append(M2PublishedEvent(
            index: published.count, monotonicNanoseconds: event.monotonicNanoseconds,
            coreMIDIHostTime: hostTime, transferSequence: event.transferSequence,
            logicalBytes: event.bytes, umpWords: words, status: status
        ))
        condition.broadcast()
        condition.unlock()
    }

    func recordMonitored(hostTime: UInt64, bytes: [UInt8], words: [UInt32]) {
        condition.lock()
        monitored.append(M2MonitoredEvent(
            index: monitored.count, coreMIDIHostTime: hostTime,
            logicalBytes: bytes, umpWords: words
        ))
        condition.broadcast()
        condition.unlock()
    }

    func recordError(_ message: String) {
        condition.lock()
        errors.append(message)
        condition.broadcast()
        condition.unlock()
    }

    func markMonitorReady() {
        condition.lock()
        monitorReady = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForMonitorReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while !monitorReady && errors.isEmpty && Date() < deadline {
            condition.wait(until: deadline)
        }
        return monitorReady
    }

    func snapshot() -> M2BoundarySnapshot {
        condition.lock(); defer { condition.unlock() }
        return M2BoundarySnapshot(published: published, monitored: monitored, errors: errors)
    }

    func waitForMonitorCount(_ count: Int, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while monitored.count < count && Date() < deadline {
            condition.wait(until: deadline)
        }
    }
}

private final class M2MonitorProcessRelay: @unchecked Sendable {
    private let evidence: M2BoundaryEvidence
    private let lock = NSLock()
    private var buffer = Data()

    init(evidence: M2BoundaryEvidence) { self.evidence = evidence }

    func consume(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let record = try JSONDecoder().decode(MIDIExternalMonitorRecord.self, from: Data(line))
                switch record.kind {
                case "ready": evidence.markMonitorReady()
                case "discovery": break
                case "event":
                    guard let hostTime = record.hostTime,
                          let bytes = record.logicalBytes,
                          let words = record.umpWords else {
                        throw M2CoreMIDIError.invalidEventList("external monitor event lacks fields")
                    }
                    evidence.recordMonitored(hostTime: hostTime, bytes: bytes, words: words)
                case "error": evidence.recordError("external Core MIDI monitor: \(record.message ?? "unknown error")")
                default: evidence.recordError("external Core MIDI monitor emitted unknown record kind")
                }
            } catch {
                evidence.recordError("external Core MIDI monitor record decode: \(error)")
            }
        }
    }
}

private final class M2ExternalMonitor: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let errorOutput = Pipe()
    private let relay: M2MonitorProcessRelay
    private let evidenceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "twitch-modern-midi-monitor-\(UUID().uuidString).jsonl"
    )
    private let refreshLock = NSLock()
    private var evidenceOffset = 0

    init(
        executableURL: URL, sourceName: String, sourceEndpoint: MIDIEndpointRef,
        evidence: M2BoundaryEvidence
    ) throws {
        relay = M2MonitorProcessRelay(evidence: evidence)
        process.executableURL = executableURL
        process.arguments = [
            "--source-name", sourceName,
            "--source-endpoint", String(sourceEndpoint),
            "--consumer-api", "modern",
            "--output-file", evidenceURL.path,
        ]
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while !evidence.waitForMonitorReady(timeout: 0), Date() < deadline {
            refresh()
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard evidence.waitForMonitorReady(timeout: 0) else {
            let records = evidence.snapshot()
            close()
            let stderr = String(
                data: errorOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let details = (records.errors + (stderr.isEmpty ? [] : [stderr]))
                .joined(separator: "; ")
            throw M2CoreMIDIError.invalidEventList(
                "external Core MIDI verification consumer did not become ready"
                    + (details.isEmpty ? "" : ": \(details)")
            )
        }
    }

    func close() {
        refresh()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: evidenceURL)
    }

    func refresh() {
        refreshLock.lock(); defer { refreshLock.unlock() }
        guard let data = try? Data(contentsOf: evidenceURL), data.count > evidenceOffset else {
            return
        }
        relay.consume(Data(data[evidenceOffset...]))
        evidenceOffset = data.count
    }

    deinit { close() }
}

final class CoreMIDIVirtualSource: @unchecked Sendable {
    static let sourceName = "Novation Twitch Modern"
    static let uniqueID: Int32 = 0x54574d31 // "TWM1"
    private static let eventListCapacity = 4_096

    private let runStartNanoseconds: UInt64
    private let evidence = M2BoundaryEvidence()
    private var client: MIDIClientRef = 0
    private var source: MIDIEndpointRef = 0
    private var externalMonitor: M2ExternalMonitor?
    private(set) var registration: M2SourceRegistration!
    private(set) var verificationEnabled: Bool
    private var closed = false

    init(
        runStartNanoseconds: UInt64, verificationEnabled: Bool,
        monitorExecutableURL: URL? = nil
    ) throws {
        self.runStartNanoseconds = runStartNanoseconds
        self.verificationEnabled = verificationEnabled

        try Self.require(
            MIDIClientCreateWithBlock("Twitch Modern Bridge" as CFString, &client) { _ in },
            "MIDIClientCreateWithBlock"
        )
        do {
            try Self.require(
                MIDISourceCreateWithProtocol(
                    client, Self.sourceName as CFString, ._1_0, &source
                ),
                "MIDISourceCreateWithProtocol"
            )
            try Self.require(
                MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, Self.uniqueID),
                "MIDIObjectSetIntegerProperty(source kMIDIPropertyUniqueID)"
            )
            try Self.require(
                MIDIObjectSetIntegerProperty(source, kMIDIPropertyPrivate, 0),
                "MIDIObjectSetIntegerProperty(kMIDIPropertyPrivate)"
            )
            if verificationEnabled {
                guard let monitorExecutableURL else {
                    throw M2CoreMIDIError.invalidEventList("verification monitor executable was not supplied")
                }
                externalMonitor = try M2ExternalMonitor(
                    executableURL: monitorExecutableURL,
                    sourceName: Self.sourceName, sourceEndpoint: source,
                    evidence: evidence
                )
            }
            registration = Self.registrationSnapshot(source: source)
        } catch {
            close()
            throw error
        }
    }

    func publish(_ events: [DecodedMIDIEvent]) {
        for event in events where event.kind != "parser-warning" {
            do {
                let messages = try MIDIUMPCodec.encode(event.bytes)
                let words = messages.flatMap { $0 }
                let hostTime = AudioConvertNanosToHostTime(
                    runStartNanoseconds &+ event.monotonicNanoseconds
                )
                let status = try send(messages: messages, hostTime: hostTime)
                evidence.recordPublished(
                    event: event, hostTime: hostTime, words: words, status: status
                )
            } catch {
                evidence.recordError(
                    "publish transfer \(event.transferSequence), bytes \(event.bytes): \(error)"
                )
            }
        }
    }

    func snapshot() -> M2BoundarySnapshot {
        externalMonitor?.refresh()
        return evidence.snapshot()
    }

    func waitForMonitorDrain(timeout: TimeInterval = 1.0) {
        let deadline = Date().addingTimeInterval(timeout)
        let expected = evidence.snapshot().published.count
        while Date() < deadline {
            externalMonitor?.refresh()
            if evidence.snapshot().monitored.count >= expected { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        externalMonitor?.close()
        externalMonitor = nil
        if source != 0 {
            _ = MIDIEndpointDispose(source)
            source = 0
        }
        if client != 0 {
            _ = MIDIClientDispose(client)
            client = 0
        }
    }

    deinit { close() }

    private func send(messages: [[UInt32]], hostTime: UInt64) throws -> OSStatus {
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Self.eventListCapacity,
            alignment: MemoryLayout<MIDIEventList>.alignment
        )
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: Self.eventListCapacity)
        let list = storage.assumingMemoryBound(to: MIDIEventList.self)
        var builder = UnsafeMutableMIDIEventListPointer(
            list, wordSize: Self.eventListCapacity / MemoryLayout<UInt32>.size,
            inProtocol: ._1_0
        )
        for words in messages {
            guard builder.append(timestamp: hostTime, words: words) != nil else {
                throw M2CoreMIDIError.invalidEventList("Core MIDI event list capacity exceeded")
            }
        }
        guard list.pointee.protocol == ._1_0 else {
            throw M2CoreMIDIError.invalidEventList("Core MIDI event list protocol changed unexpectedly")
        }
        guard list.pointee.numPackets == UInt32(messages.count) else {
            throw M2CoreMIDIError.invalidEventList(
                "Core MIDI event list contains \(list.pointee.numPackets) packets; expected \(messages.count)"
            )
        }
        let status = MIDIReceivedEventList(source, list)
        try Self.require(status, "MIDIReceivedEventList")
        return status
    }

    private static func registrationSnapshot(source: MIDIEndpointRef) -> M2SourceRegistration {
        let count = Int(MIDIGetNumberOfSources())
        var found = false
        var name: String?
        for index in 0..<count {
            let candidate = MIDIGetSource(index)
            if candidate == source {
                found = true
                name = stringProperty(candidate, key: kMIDIPropertyName)
            }
        }
        var protocolValue: Int32 = 0
        let protocolStatus = MIDIObjectGetIntegerProperty(
            source, kMIDIPropertyProtocolID, &protocolValue
        )
        return M2SourceRegistration(
            sourceName: Self.sourceName, sourceEndpoint: source,
            enumeratedSourceCount: count, foundByEndpoint: found,
            enumeratedName: name,
            protocolID: protocolStatus == noErr ? protocolValue : nil
        )
    }

    private static func stringProperty(_ object: MIDIObjectRef, key: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, key, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func require(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw M2CoreMIDIError.status(operation, status) }
    }
}
