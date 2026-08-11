import CoreMIDI
import Foundation
import TwitchProbeCore

struct M4DestinationRegistration: Codable {
    let destinationName: String
    let destinationEndpoint: UInt32
    let enumeratedDestinationCount: Int
    let foundByEndpoint: Bool
    let enumeratedName: String?
    let protocolID: Int32?
}

struct M4CoreMIDIOutputEvent: Codable {
    let index: Int
    let coreMIDIHostTime: UInt64
    let logicalBytes: [UInt8]
    let umpWords: [UInt32]
    let accepted: Bool
    let error: String?
}

struct M4DestinationSnapshot {
    let events: [M4CoreMIDIOutputEvent]
    let errors: [String]
}

private final class M4DestinationEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [M4CoreMIDIOutputEvent] = []
    private var errors: [String] = []

    func record(hostTime: UInt64, bytes: [UInt8], words: [UInt32], accepted: Bool, error: String?) {
        lock.lock(); defer { lock.unlock() }
        events.append(M4CoreMIDIOutputEvent(
            index: events.count, coreMIDIHostTime: hostTime, logicalBytes: bytes,
            umpWords: words, accepted: accepted, error: error
        ))
    }

    func recordError(_ error: String) {
        lock.lock(); defer { lock.unlock() }
        errors.append(error)
    }

    func snapshot() -> M4DestinationSnapshot {
        lock.lock(); defer { lock.unlock() }
        return M4DestinationSnapshot(events: events, errors: errors)
    }
}

private final class M4DestinationReceiver: @unchecked Sendable {
    typealias Sink = @Sendable ([[UInt8]]) throws -> Void

    private let evidence: M4DestinationEvidence
    private let sink: Sink
    private let lock = NSLock()
    private let decoder = MIDIUMPStreamDecoder()

    init(evidence: M4DestinationEvidence, sink: @escaping Sink) {
        self.evidence = evidence
        self.sink = sink
    }

    func receive(_ list: UnsafePointer<MIDIEventList>) {
        lock.lock(); defer { lock.unlock() }
        guard list.pointee.protocol == ._1_0 else {
            evidence.recordError("Core MIDI destination received non-MIDI-1.0 event list")
            return
        }
        do {
            var accepted: [(hostTime: UInt64, bytes: [UInt8], words: [UInt32])] = []
            let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet)!
            var packet = UnsafeRawPointer(list).advanced(by: packetOffset)
                .assumingMemoryBound(to: MIDIEventPacket.self)
            let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words)!
            for _ in 0..<Int(list.pointee.numPackets) {
                let count = Int(packet.pointee.wordCount)
                let packetWords = Array(UnsafeBufferPointer(
                    start: UnsafeRawPointer(packet).advanced(by: wordsOffset)
                        .assumingMemoryBound(to: UInt32.self),
                    count: count
                ))
                var offset = 0
                while offset < packetWords.count {
                    let wordCount = try MIDIUMPCodec.wordCount(firstWord: packetWords[offset])
                    guard offset + wordCount <= packetWords.count else {
                        throw M2CoreMIDIError.invalidEventList("truncated UMP at virtual destination")
                    }
                    let words = Array(packetWords[offset..<(offset + wordCount)])
                    for bytes in try decoder.consume(words: words) {
                        do {
                            try TwitchBasicOutputPolicy.validate(bytes)
                            accepted.append((packet.pointee.timeStamp, bytes, words))
                        } catch {
                            evidence.record(
                                hostTime: packet.pointee.timeStamp, bytes: bytes, words: words,
                                accepted: false, error: String(describing: error)
                            )
                        }
                    }
                    offset += wordCount
                }
                packet = UnsafePointer(MIDIEventPacketNext(UnsafeMutablePointer(mutating: packet)))
            }
            guard !accepted.isEmpty else { return }
            do {
                try sink(accepted.map(\.bytes))
                for item in accepted {
                    evidence.record(
                        hostTime: item.hostTime, bytes: item.bytes, words: item.words,
                        accepted: true, error: nil
                    )
                }
            } catch {
                let message = "USB output rejected Core MIDI batch: \(error)"
                evidence.recordError(message)
                for item in accepted {
                    evidence.record(
                        hostTime: item.hostTime, bytes: item.bytes, words: item.words,
                        accepted: false, error: message
                    )
                }
            }
        } catch {
            evidence.recordError("Core MIDI destination decode failed: \(error)")
        }
    }
}

final class CoreMIDIVirtualDestination: @unchecked Sendable {
    static let destinationName = "Novation Twitch Modern"
    static let uniqueID: Int32 = 0x54574d32 // "TWM2"

    private let evidence = M4DestinationEvidence()
    private let receiver: M4DestinationReceiver
    private let receiveBlock: MIDIReceiveBlock
    private var client: MIDIClientRef = 0
    private var destination: MIDIEndpointRef = 0
    private var closed = false
    private(set) var registration: M4DestinationRegistration!

    init(sink: @escaping @Sendable ([[UInt8]]) throws -> Void) throws {
        receiver = M4DestinationReceiver(evidence: evidence, sink: sink)
        receiveBlock = { [receiver] list, _ in receiver.receive(list) }
        try Self.require(
            MIDIClientCreateWithBlock("Twitch Modern Output Bridge" as CFString, &client) { _ in },
            "MIDIClientCreateWithBlock(output)"
        )
        do {
            try Self.require(
                MIDIDestinationCreateWithProtocol(
                    client, Self.destinationName as CFString, ._1_0,
                    &destination, receiveBlock
                ),
                "MIDIDestinationCreateWithProtocol"
            )
            try Self.require(
                MIDIObjectSetIntegerProperty(
                    destination, kMIDIPropertyUniqueID, Self.uniqueID
                ),
                "MIDIObjectSetIntegerProperty(destination kMIDIPropertyUniqueID)"
            )
            try Self.require(
                MIDIObjectSetIntegerProperty(destination, kMIDIPropertyPrivate, 0),
                "MIDIObjectSetIntegerProperty(output kMIDIPropertyPrivate)"
            )
            registration = Self.registrationSnapshot(destination: destination)
        } catch {
            close()
            throw error
        }
    }

    func snapshot() -> M4DestinationSnapshot { evidence.snapshot() }

    func close() {
        guard !closed else { return }
        closed = true
        if destination != 0 {
            _ = MIDIEndpointDispose(destination)
            destination = 0
        }
        if client != 0 {
            _ = MIDIClientDispose(client)
            client = 0
        }
    }

    deinit { close() }

    private static func registrationSnapshot(
        destination: MIDIEndpointRef
    ) -> M4DestinationRegistration {
        let count = Int(MIDIGetNumberOfDestinations())
        var found = false
        var name: String?
        for index in 0..<count {
            let candidate = MIDIGetDestination(index)
            if candidate == destination {
                found = true
                name = stringProperty(candidate, key: kMIDIPropertyName)
            }
        }
        var protocolValue: Int32 = 0
        let protocolStatus = MIDIObjectGetIntegerProperty(
            destination, kMIDIPropertyProtocolID, &protocolValue
        )
        return M4DestinationRegistration(
            destinationName: Self.destinationName,
            destinationEndpoint: destination,
            enumeratedDestinationCount: count,
            foundByEndpoint: found, enumeratedName: name,
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
