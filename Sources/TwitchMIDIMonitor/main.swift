import CoreMIDI
import Darwin
import Foundation
import TwitchProbeCore

private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let file: FileHandle?

    init(fileURL: URL?) {
        if let fileURL {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            file = try? FileHandle(forWritingTo: fileURL)
        } else {
            file = nil
        }
    }

    func send(_ record: MIDIExternalMonitorRecord) {
        lock.lock(); defer { lock.unlock() }
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0a)
        try? FileHandle.standardOutput.write(contentsOf: data)
        try? file?.write(contentsOf: data)
        try? file?.synchronize()
    }
}

private final class Receiver: @unchecked Sendable {
    let output: Output
    let midiParser = MIDIByteStreamParser(maximumSysExBytes: 1_024)
    let umpDecoder = MIDIUMPStreamDecoder()
    private var packetSequence = 0

    init(output: Output) { self.output = output }

    func receiveModern(_ list: UnsafePointer<MIDIEventList>) {
        do {
            let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet)!
            var packet = UnsafeRawPointer(list).advanced(by: packetOffset)
                .assumingMemoryBound(to: MIDIEventPacket.self)
            let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words)!
            for _ in 0..<Int(list.pointee.numPackets) {
                let count = Int(packet.pointee.wordCount)
                let pointer = UnsafeRawPointer(packet).advanced(by: wordsOffset)
                    .assumingMemoryBound(to: UInt32.self)
                let packetWords = Array(UnsafeBufferPointer(start: pointer, count: count))
                var offset = 0
                while offset < packetWords.count {
                    let wordCount = try MIDIUMPCodec.wordCount(firstWord: packetWords[offset])
                    guard offset + wordCount <= packetWords.count else {
                        throw MonitorError.message("truncated UMP event")
                    }
                    let words = Array(packetWords[offset..<(offset + wordCount)])
                    for bytes in try umpDecoder.consume(words: words) {
                        output.send(MIDIExternalMonitorRecord(
                            kind: "event", hostTime: packet.pointee.timeStamp,
                            logicalBytes: bytes, umpWords: words, api: "modern"
                        ))
                    }
                    offset += wordCount
                }
                packet = UnsafePointer(MIDIEventPacketNext(UnsafeMutablePointer(mutating: packet)))
            }
        } catch {
            output.send(MIDIExternalMonitorRecord(
                kind: "error", message: String(describing: error), api: "modern"
            ))
        }
    }

    func receiveLegacy(_ list: UnsafePointer<MIDIPacketList>) {
        let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
        var packet = UnsafeRawPointer(list).advanced(by: packetOffset)
            .assumingMemoryBound(to: MIDIPacket.self)
        for _ in 0..<Int(list.pointee.numPackets) {
            packetSequence += 1
            let length = Int(packet.pointee.length)
            let bytes = withUnsafeBytes(of: packet.pointee.data) {
                Array($0.prefix(length))
            }
            let events = midiParser.consume(
                bytes, monotonicNanoseconds: 0, transferSequence: packetSequence
            )
            for event in events where event.kind != "parser-warning" {
                output.send(MIDIExternalMonitorRecord(
                    kind: "event", hostTime: packet.pointee.timeStamp,
                    logicalBytes: event.bytes, umpWords: [], api: "legacy"
                ))
            }
            packet = UnsafePointer(MIDIPacketNext(UnsafeMutablePointer(mutating: packet)))
        }
    }
}

private enum MonitorError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case let .message(value): value }
    }
}

private func require(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw MonitorError.message("\(operation) failed with OSStatus \(status)")
    }
}

private nonisolated func makeNotificationBlock() -> MIDINotifyBlock {
    { _ in }
}

private nonisolated func makeModernReceiveBlock(_ receiver: Receiver) -> MIDIReceiveBlock {
    { eventList, _ in receiver.receiveModern(eventList) }
}

private nonisolated func makeLegacyReceiveBlock(_ receiver: Receiver) -> MIDIReadBlock {
    { packetList, _ in receiver.receiveLegacy(packetList) }
}

private let arguments = CommandLine.arguments
guard let nameIndex = arguments.firstIndex(of: "--source-name"), nameIndex + 1 < arguments.count else {
    FileHandle.standardError.write(Data("missing --source-name\n".utf8))
    exit(EXIT_FAILURE)
}
let sourceName = arguments[nameIndex + 1]
let consumerAPI: String = {
    guard let index = arguments.firstIndex(of: "--consumer-api"), index + 1 < arguments.count else {
        return "legacy"
    }
    return arguments[index + 1]
}()
guard consumerAPI == "modern" || consumerAPI == "legacy" else {
    FileHandle.standardError.write(Data("invalid --consumer-api; use modern or legacy\n".utf8))
    exit(EXIT_FAILURE)
}
guard let endpointIndex = arguments.firstIndex(of: "--source-endpoint"),
      endpointIndex + 1 < arguments.count,
      let expectedEndpoint = UInt32(arguments[endpointIndex + 1]) else {
    FileHandle.standardError.write(Data("missing or invalid --source-endpoint\n".utf8))
    exit(EXIT_FAILURE)
}
let outputFileURL: URL? = {
    guard let index = arguments.firstIndex(of: "--output-file"), index + 1 < arguments.count else {
        return nil
    }
    return URL(fileURLWithPath: arguments[index + 1])
}()
private let output = Output(fileURL: outputFileURL)
private let receiver = Receiver(output: output)
private let retainedNotificationBlock = makeNotificationBlock()
private let retainedModernReceiveBlock = makeModernReceiveBlock(receiver)
private let retainedLegacyReceiveBlock = makeLegacyReceiveBlock(receiver)
var client: MIDIClientRef = 0
var port: MIDIPortRef = 0

do {
    try require(
        MIDIClientCreateWithBlock(
            "Twitch Modern External Verifier" as CFString, &client,
            retainedNotificationBlock
        ),
        "MIDIClientCreateWithBlock"
    )
    if consumerAPI == "modern" {
        try require(
            MIDIInputPortCreateWithProtocol(
                client, "Core MIDI Synthetic Modern Input" as CFString, ._1_0, &port,
                retainedModernReceiveBlock
            ),
            "MIDIInputPortCreateWithProtocol"
        )
    } else {
        try require(
            MIDIInputPortCreateWithBlock(
                client, "Core MIDI Synthetic Legacy Input" as CFString, &port,
                retainedLegacyReceiveBlock
            ),
            "MIDIInputPortCreateWithBlock"
        )
    }
    var matched: MIDIEndpointRef = 0
    for index in 0..<Int(MIDIGetNumberOfSources()) {
        let candidate = MIDIGetSource(index)
        var value: Unmanaged<CFString>?
        if candidate == expectedEndpoint,
           MIDIObjectGetStringProperty(candidate, kMIDIPropertyName, &value) == noErr,
           value?.takeRetainedValue() as String? == sourceName {
            matched = candidate
            break
        }
    }
    guard matched != 0 else { throw MonitorError.message("source not found: \(sourceName)") }
    var protocolID: Int32 = 0
    let protocolStatus = MIDIObjectGetIntegerProperty(
        matched, kMIDIPropertyProtocolID, &protocolID
    )
    output.send(MIDIExternalMonitorRecord(
        kind: "discovery", message: sourceName, api: consumerAPI,
        sourceEndpoint: matched,
        protocolID: protocolStatus == noErr ? protocolID : nil,
        status: protocolStatus, sourceCount: Int(MIDIGetNumberOfSources())
    ))
    let connectionStatus = MIDIPortConnectSource(port, matched, nil)
    try require(connectionStatus, "MIDIPortConnectSource")
    output.send(MIDIExternalMonitorRecord(
        kind: "ready", message: "\(sourceName) endpoint \(matched)", api: consumerAPI,
        sourceEndpoint: matched,
        protocolID: protocolStatus == noErr ? protocolID : nil,
        status: connectionStatus, sourceCount: Int(MIDIGetNumberOfSources())
    ))
    dispatchMain()
} catch {
    output.send(MIDIExternalMonitorRecord(kind: "error", message: String(describing: error)))
    if port != 0 { _ = MIDIPortDispose(port) }
    if client != 0 { _ = MIDIClientDispose(client) }
    exit(EXIT_FAILURE)
}
