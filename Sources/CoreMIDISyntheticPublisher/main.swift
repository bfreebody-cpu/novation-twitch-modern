import CoreAudio
import CoreMIDI
import Darwin
import Foundation
import TwitchProbeCore

private enum TestPath: String, Codable {
    case modern
    case legacy
}

private enum ModernLayout: String, Codable {
    case stack
    case rawProduction = "raw-production"
    case typed
}

private struct Emission: Codable {
    let label: String
    let logicalBytes: [UInt8]
    let umpWords: [UInt32]
    let hostTime: UInt64
    let api: String
    let status: Int32
}

private struct SyntheticCapture: Codable {
    let schemaVersion: Int
    let path: TestPath
    let modernLayout: ModernLayout?
    let consumerAPI: String
    let messageProfile: String
    let publicationQueue: String
    let timestampMode: String
    let startedAtUTC: String
    let endedAtUTC: String
    let sourceName: String
    let publisherPID: Int32
    let consumerPID: Int32
    let sourceEndpoint: UInt32
    let sourceCreationAPI: String
    let sourceCreationStatus: Int32
    let sourceProtocolPropertyStatus: Int32
    let sourceProtocolID: Int32?
    let sourcePrivatePropertyStatus: Int32
    let sourcePrivateValue: Int32?
    let consumerRecords: [MIDIExternalMonitorRecord]
    let emissions: [Emission]
    let receivedLogicalMessages: [[UInt8]]
    let exactMatch: Bool
    let consumerExitStatus: Int32?
    let consumerStandardError: String
}

private enum SyntheticError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case let .message(value): value }
    }
}

private final class ConsumerRelay: @unchecked Sendable {
    private let condition = NSCondition()
    private var bytes = Data()
    private var records: [MIDIExternalMonitorRecord] = []

    func consume(_ data: Data) {
        condition.lock(); defer { condition.unlock() }
        bytes.append(data)
        while let newline = bytes.firstIndex(of: 0x0a) {
            let line = Data(bytes[..<newline])
            bytes.removeSubrange(...newline)
            if !line.isEmpty, let record = try? JSONDecoder().decode(
                MIDIExternalMonitorRecord.self, from: line
            ) {
                records.append(record)
            }
        }
        condition.broadcast()
    }

    func waitForReady(timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) { $0.contains { $0.kind == "ready" } }
    }

    func waitForEventCount(_ count: Int, timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) { $0.filter { $0.kind == "event" }.count >= count }
    }

    func snapshot() -> [MIDIExternalMonitorRecord] {
        condition.lock(); defer { condition.unlock() }
        return records
    }

    private func wait(
        timeout: TimeInterval, predicate: ([MIDIExternalMonitorRecord]) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while !predicate(records) && Date() < deadline {
            condition.wait(until: deadline)
        }
        return predicate(records)
    }
}

private final class EmissionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[Emission], Error>?

    func store(_ value: Result<[Emission], Error>) {
        lock.lock(); result = value; lock.unlock()
    }

    func load() throws -> [Emission] {
        lock.lock(); defer { lock.unlock() }
        guard let result else { throw SyntheticError.message("background emission produced no result") }
        return try result.get()
    }
}

private func require(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw SyntheticError.message("\(operation) failed with OSStatus \(status)")
    }
}

private func modernPublish(
    source: MIDIEndpointRef, words: [UInt32], hostTime: UInt64,
    layout: ModernLayout
) throws -> OSStatus {
    func publish(_ pointer: UnsafeMutablePointer<MIDIEventList>, wordSize: Int) throws -> OSStatus {
        var builder = UnsafeMutableMIDIEventListPointer(
            pointer, wordSize: wordSize,
            inProtocol: ._1_0
        )
        guard builder.append(timestamp: hostTime, words: words) != nil else {
            throw SyntheticError.message("UnsafeMutableMIDIEventListPointer.append failed")
        }
        guard pointer.pointee.protocol == ._1_0,
              pointer.pointee.numPackets == 1 else {
            throw SyntheticError.message("modern event list failed structural validation")
        }
        return MIDIReceivedEventList(source, pointer)
    }
    switch layout {
    case .stack:
        var list = MIDIEventList()
        return try withUnsafeMutablePointer(to: &list) { pointer in
            try publish(
                pointer,
                wordSize: MemoryLayout<MIDIEventList>.size / MemoryLayout<UInt32>.size
            )
        }
    case .rawProduction:
        let byteCount = 4_096
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<MIDIEventList>.alignment
        )
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        return try publish(
            raw.assumingMemoryBound(to: MIDIEventList.self),
            wordSize: byteCount / MemoryLayout<UInt32>.size
        )
    case .typed:
        let count = 16
        let pointer = UnsafeMutablePointer<MIDIEventList>.allocate(capacity: count)
        pointer.initialize(repeating: MIDIEventList(), count: count)
        defer {
            pointer.deinitialize(count: count)
            pointer.deallocate()
        }
        return try publish(
            pointer,
            wordSize: count * MemoryLayout<MIDIEventList>.size / MemoryLayout<UInt32>.size
        )
    }
}

private func legacyPublish(
    source: MIDIEndpointRef, bytes: [UInt8], hostTime: UInt64
) throws -> OSStatus {
    var list = MIDIPacketList()
    return try withUnsafeMutablePointer(to: &list) { pointer in
        let initial = MIDIPacketListInit(pointer)
        let added = bytes.withUnsafeBufferPointer { buffer in
            MIDIPacketListAdd(
                pointer, MemoryLayout<MIDIPacketList>.size, initial, hostTime,
                bytes.count, buffer.baseAddress!
            )
        }
        guard UInt(bitPattern: added) != 0 else {
            throw SyntheticError.message("MIDIPacketListAdd failed")
        }
        return MIDIReceived(source, pointer)
    }
}

private func wallTime() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func captureDirectory(path: TestPath, consumerAPI: String) throws -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let layoutSuffix: String
    if path == .modern {
        let layout = CommandLine.arguments.firstIndex(of: "--modern-layout").flatMap { index in
            index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
        } ?? ModernLayout.stack.rawValue
        layoutSuffix = "-\(layout)-consumer-\(consumerAPI)"
    } else {
        layoutSuffix = ""
    }
    let url = root.appendingPathComponent("captures").appendingPathComponent(
        "\(formatter.string(from: Date()))-coremidi-synthetic-\(path.rawValue)\(layoutSuffix)"
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let arguments = CommandLine.arguments
guard let pathIndex = arguments.firstIndex(of: "--path"), pathIndex + 1 < arguments.count,
      let path = TestPath(rawValue: arguments[pathIndex + 1]) else {
    FileHandle.standardError.write(Data("usage: coremidi-synthetic-publisher --path modern|legacy\n".utf8))
    exit(EXIT_FAILURE)
}
private let modernLayout: ModernLayout = {
    guard let index = arguments.firstIndex(of: "--modern-layout"), index + 1 < arguments.count,
          let value = ModernLayout(rawValue: arguments[index + 1]) else { return .stack }
    return value
}()
let consumerAPI: String = {
    guard let index = arguments.firstIndex(of: "--consumer-api"), index + 1 < arguments.count else {
        return path.rawValue
    }
    return arguments[index + 1]
}()
guard consumerAPI == "modern" || consumerAPI == "legacy" else {
    FileHandle.standardError.write(Data("invalid --consumer-api; use modern or legacy\n".utf8))
    exit(EXIT_FAILURE)
}
let messageProfile: String = {
    guard let index = arguments.firstIndex(of: "--message-profile"), index + 1 < arguments.count else {
        return "standard"
    }
    return arguments[index + 1]
}()
guard messageProfile == "standard" || messageProfile == "twitch-codec" else {
    FileHandle.standardError.write(Data("invalid --message-profile\n".utf8))
    exit(EXIT_FAILURE)
}
let publicationQueue: String = {
    guard let index = arguments.firstIndex(of: "--publication-queue"), index + 1 < arguments.count else {
        return "main"
    }
    return arguments[index + 1]
}()
guard publicationQueue == "main" || publicationQueue == "background"
        || publicationQueue == "background-blocked-main" else {
    FileHandle.standardError.write(Data("invalid --publication-queue\n".utf8))
    exit(EXIT_FAILURE)
}
let timestampMode: String = {
    guard let index = arguments.firstIndex(of: "--timestamp-mode"), index + 1 < arguments.count else {
        return "direct"
    }
    return arguments[index + 1]
}()
guard timestampMode == "direct" || timestampMode == "reconstructed" else {
    FileHandle.standardError.write(Data("invalid --timestamp-mode\n".utf8))
    exit(EXIT_FAILURE)
}

let startedAt = wallTime()
var client: MIDIClientRef = 0
var source: MIDIEndpointRef = 0
var consumer: Process?
var outputHandle: FileHandle?

do {
    let directory = try captureDirectory(path: path, consumerAPI: consumerAPI)
    let sourceName = "Core MIDI Synthetic \(path.rawValue.capitalized)"
    let clientStatus = MIDIClientCreateWithBlock(
        "Core MIDI Synthetic Publisher" as CFString, &client
    ) { _ in }
    try require(clientStatus, "MIDIClientCreateWithBlock")

    let sourceCreationAPI: String
    let sourceStatus: OSStatus
    switch path {
    case .modern:
        sourceCreationAPI = "MIDISourceCreateWithProtocol"
        sourceStatus = MIDISourceCreateWithProtocol(
            client, sourceName as CFString, ._1_0, &source
        )
    case .legacy:
        sourceCreationAPI = "MIDISourceCreate"
        sourceStatus = MIDISourceCreate(client, sourceName as CFString, &source)
    }
    try require(sourceStatus, sourceCreationAPI)
    try require(
        MIDIObjectSetIntegerProperty(source, kMIDIPropertyPrivate, 0),
        "MIDIObjectSetIntegerProperty(kMIDIPropertyPrivate)"
    )

    var protocolValue: Int32 = 0
    let protocolStatus = MIDIObjectGetIntegerProperty(
        source, kMIDIPropertyProtocolID, &protocolValue
    )
    var privateValue: Int32 = -1
    let privateStatus = MIDIObjectGetIntegerProperty(
        source, kMIDIPropertyPrivate, &privateValue
    )

    let relay = ConsumerRelay()
    let process = Process()
    consumer = process
    let publisherURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.executableURL = publisherURL.deletingLastPathComponent()
        .appendingPathComponent("twitch-midi-monitor")
    process.arguments = [
        "--source-name", sourceName,
        "--source-endpoint", String(source),
        "--consumer-api", consumerAPI,
    ]
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError
    outputHandle = standardOutput.fileHandleForReading
    standardOutput.fileHandleForReading.readabilityHandler = { [relay] handle in
        let data = handle.availableData
        if !data.isEmpty { relay.consume(data) }
    }
    try process.run()
    guard relay.waitForReady(timeout: 5) else {
        throw SyntheticError.message("consumer did not discover/connect to source within 5 seconds")
    }

    let noteOnBytes: [UInt8] = messageProfile == "twitch-codec"
        ? [0x97, 0x17, 0x7f] : [0x90, 0x3c, 0x64]
    let noteOffBytes: [UInt8] = messageProfile == "twitch-codec"
        ? [0x97, 0x17, 0x00] : [0x80, 0x3c, 0x00]
    let noteOnWords: [UInt32] = messageProfile == "twitch-codec"
        ? try MIDIUMPCodec.encode(noteOnBytes).flatMap { $0 }
        : [MIDI1UPNoteOn(0, 0, 60, 100)]
    let noteOffWords: [UInt32] = messageProfile == "twitch-codec"
        ? try MIDIUMPCodec.encode(noteOffBytes).flatMap { $0 }
        : [MIDI1UPNoteOff(0, 0, 60, 0)]
    let publicationEndpoint = source
    let reconstructionOrigin = DispatchTime.now().uptimeNanoseconds

    let emit: @Sendable () throws -> [Emission] = {
        var values: [Emission] = []
        for (label, bytes, words) in [
            ("note-on", noteOnBytes, noteOnWords),
            ("note-off", noteOffBytes, noteOffWords),
        ] {
            let timestamp: UInt64
            if timestampMode == "reconstructed" {
                let elapsed = DispatchTime.now().uptimeNanoseconds - reconstructionOrigin
                timestamp = AudioConvertNanosToHostTime(reconstructionOrigin + elapsed)
            } else {
                timestamp = AudioGetCurrentHostTime()
            }
            let status: OSStatus
            switch path {
            case .modern:
                status = try modernPublish(
                    source: publicationEndpoint, words: words, hostTime: timestamp,
                    layout: modernLayout
                )
            case .legacy:
                status = try legacyPublish(
                    source: publicationEndpoint, bytes: bytes, hostTime: timestamp
                )
            }
            values.append(Emission(
                label: label, logicalBytes: bytes, umpWords: words,
                hostTime: timestamp,
                api: path == .modern ? "MIDIReceivedEventList" : "MIDIReceived",
                status: status
            ))
            usleep(100_000)
        }
        return values
    }
    let emissions: [Emission]
    if publicationQueue == "background" {
        emissions = try DispatchQueue.global().sync { try emit() }
    } else if publicationQueue == "background-blocked-main" {
        let box = EmissionBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.store(Result { try emit() })
            semaphore.signal()
        }
        semaphore.wait()
        emissions = try box.load()
    } else {
        emissions = try emit()
    }
    _ = relay.waitForEventCount(2, timeout: 3)

    standardOutput.fileHandleForReading.readabilityHandler = nil
    if process.isRunning { process.terminate(); process.waitUntilExit() }
    let consumerError = String(
        data: standardError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let records = relay.snapshot()
    let received = records.filter { $0.kind == "event" }.compactMap(\.logicalBytes)
    let expected = [noteOnBytes, noteOffBytes]
    let capture = SyntheticCapture(
        schemaVersion: 1, path: path,
        modernLayout: path == .modern ? modernLayout : nil,
        consumerAPI: consumerAPI,
        messageProfile: messageProfile, publicationQueue: publicationQueue,
        timestampMode: timestampMode,
        startedAtUTC: startedAt, endedAtUTC: wallTime(),
        sourceName: sourceName, publisherPID: getpid(), consumerPID: process.processIdentifier,
        sourceEndpoint: source, sourceCreationAPI: sourceCreationAPI,
        sourceCreationStatus: sourceStatus,
        sourceProtocolPropertyStatus: protocolStatus,
        sourceProtocolID: protocolStatus == noErr ? protocolValue : nil,
        sourcePrivatePropertyStatus: privateStatus,
        sourcePrivateValue: privateStatus == noErr ? privateValue : nil,
        consumerRecords: records, emissions: emissions,
        receivedLogicalMessages: received, exactMatch: received == expected,
        consumerExitStatus: process.terminationStatus,
        consumerStandardError: consumerError
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(capture).write(to: directory.appendingPathComponent("capture.json"))
    for record in records {
        var data = try JSONEncoder().encode(record)
        data.append(0x0a)
        let url = directory.appendingPathComponent("consumer.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        }
    }
    print("path=\(path.rawValue) layout=\(path == .modern ? modernLayout.rawValue : "n/a") consumer=\(consumerAPI) source=\(source) protocol=\(protocolStatus == noErr ? String(protocolValue) : "unavailable")")
    for emission in emissions {
        print("emit \(emission.label) timestamp=\(emission.hostTime) status=\(emission.status) bytes=\(emission.logicalBytes) words=\(emission.umpWords)")
    }
    print("received=\(received) exactMatch=\(capture.exactMatch)")
    print("capture=\(directory.path)")
    _ = MIDIEndpointDispose(source)
    source = 0
    _ = MIDIClientDispose(client)
    client = 0
    exit(capture.exactMatch ? EXIT_SUCCESS : 2)
} catch {
    outputHandle?.readabilityHandler = nil
    if let consumer, consumer.isRunning { consumer.terminate(); consumer.waitUntilExit() }
    if source != 0 { _ = MIDIEndpointDispose(source) }
    if client != 0 { _ = MIDIClientDispose(client) }
    FileHandle.standardError.write(Data("synthetic Core MIDI test: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
