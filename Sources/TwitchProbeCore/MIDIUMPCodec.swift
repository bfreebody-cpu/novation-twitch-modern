import Foundation

public enum MIDIUMPCodecError: Error, CustomStringConvertible, Equatable {
    case invalidMIDI([UInt8])
    case unsupportedUMP(UInt32)
    case malformedSysEx([UInt8])

    public var description: String {
        switch self {
        case let .invalidMIDI(bytes): "invalid logical MIDI message: \(bytes)"
        case let .unsupportedUMP(word): String(format: "unsupported UMP word 0x%08x", word)
        case let .malformedSysEx(bytes): "malformed MIDI 1.0 SysEx: \(bytes)"
        }
    }
}

/// Pure MIDI 1.0 <-> Universal MIDI Packet conversion used at the Core MIDI boundary.
/// Channel numbers, status bytes, data bytes and encoder values are not remapped.
public enum MIDIUMPCodec {
    public static func encode(_ bytes: [UInt8], group: UInt8 = 0) throws -> [[UInt32]] {
        guard let status = bytes.first, status & 0x80 != 0 else {
            throw MIDIUMPCodecError.invalidMIDI(bytes)
        }
        let groupNibble = UInt32(group & 0x0f) << 24
        if status < 0xf0 {
            let required = channelDataLength(status: status) + 1
            guard bytes.count == required else { throw MIDIUMPCodecError.invalidMIDI(bytes) }
            let data1 = bytes.count > 1 ? bytes[1] : 0
            let data2 = bytes.count > 2 ? bytes[2] : 0
            let word = UInt32(0x20_00_00_00) | groupNibble | UInt32(status) << 16
                | UInt32(data1 & 0x7f) << 8 | UInt32(data2 & 0x7f)
            return [[word]]
        }
        if status == 0xf0 { return try encodeSysEx(bytes, group: group) }
        let required = systemDataLength(status: status) + 1
        guard bytes.count == required else { throw MIDIUMPCodecError.invalidMIDI(bytes) }
        let data1 = bytes.count > 1 ? bytes[1] : 0
        let data2 = bytes.count > 2 ? bytes[2] : 0
        let word = UInt32(0x10_00_00_00) | groupNibble | UInt32(status) << 16
            | UInt32(data1 & 0x7f) << 8 | UInt32(data2 & 0x7f)
        return [[word]]
    }

    public static func wordCount(firstWord: UInt32) throws -> Int {
        switch (firstWord >> 28) & 0x0f {
        case 0x0, 0x1, 0x2, 0x6, 0x7: 1
        case 0x3, 0x4, 0x8, 0x9, 0xa: 2
        case 0xb, 0xc: 3
        case 0x5, 0xd, 0xe, 0xf: 4
        default: throw MIDIUMPCodecError.unsupportedUMP(firstWord)
        }
    }

    private static func encodeSysEx(_ bytes: [UInt8], group: UInt8) throws -> [[UInt32]] {
        guard bytes.count >= 2, bytes.first == 0xf0, bytes.last == 0xf7,
              bytes.dropFirst().dropLast().allSatisfy({ $0 < 0x80 }) else {
            throw MIDIUMPCodecError.malformedSysEx(bytes)
        }
        let payload = Array(bytes.dropFirst().dropLast())
        let chunks: [[UInt8]] = payload.isEmpty
            ? [[]]
            : stride(from: 0, to: payload.count, by: 6).map {
                Array(payload[$0..<min($0 + 6, payload.count)])
            }
        return chunks.enumerated().map { index, chunk in
            let status: UInt8
            if chunks.count == 1 { status = 0 }
            else if index == 0 { status = 1 }
            else if index == chunks.count - 1 { status = 3 }
            else { status = 2 }
            let padded = chunk + Array(repeating: 0, count: 6 - chunk.count)
            let word0 = UInt32(0x30_00_00_00) | UInt32(group & 0x0f) << 24
                | UInt32((status << 4) | UInt8(chunk.count)) << 16
                | UInt32(padded[0]) << 8 | UInt32(padded[1])
            let word1 = UInt32(padded[2]) << 24 | UInt32(padded[3]) << 16
                | UInt32(padded[4]) << 8 | UInt32(padded[5])
            return [word0, word1]
        }
    }

    fileprivate static func channelDataLength(status: UInt8) -> Int {
        status & 0xf0 == 0xc0 || status & 0xf0 == 0xd0 ? 1 : 2
    }

    fileprivate static func systemDataLength(status: UInt8) -> Int {
        switch status { case 0xf1, 0xf3: 1; case 0xf2: 2; default: 0 }
    }
}

public final class MIDIUMPStreamDecoder: @unchecked Sendable {
    private var systemExclusive: [UInt8]?

    public init() {}

    public func consume(words: [UInt32]) throws -> [[UInt8]] {
        guard let first = words.first else { throw MIDIUMPCodecError.invalidMIDI([]) }
        switch (first >> 28) & 0x0f {
        case 0x1:
            guard words.count == 1 else { throw MIDIUMPCodecError.unsupportedUMP(first) }
            let status = UInt8((first >> 16) & 0xff)
            let length: Int
            switch status { case 0xf1, 0xf3: length = 2; case 0xf2: length = 3; default: length = 1 }
            let all = [status, UInt8((first >> 8) & 0x7f), UInt8(first & 0x7f)]
            return [Array(all.prefix(length))]
        case 0x2:
            guard words.count == 1 else { throw MIDIUMPCodecError.unsupportedUMP(first) }
            let status = UInt8((first >> 16) & 0xff)
            let length = MIDIUMPCodec.channelDataLength(status: status) + 1
            let all = [status, UInt8((first >> 8) & 0x7f), UInt8(first & 0x7f)]
            return [Array(all.prefix(length))]
        case 0x3:
            guard words.count == 2 else { throw MIDIUMPCodecError.unsupportedUMP(first) }
            return try consumeSysEx(first: first, second: words[1])
        default:
            throw MIDIUMPCodecError.unsupportedUMP(first)
        }
    }

    private func consumeSysEx(first: UInt32, second: UInt32) throws -> [[UInt8]] {
        let status = UInt8((first >> 20) & 0x0f)
        let count = Int((first >> 16) & 0x0f)
        guard count <= 6, status <= 3 else { throw MIDIUMPCodecError.unsupportedUMP(first) }
        let available = [
            UInt8((first >> 8) & 0x7f), UInt8(first & 0x7f),
            UInt8((second >> 24) & 0x7f), UInt8((second >> 16) & 0x7f),
            UInt8((second >> 8) & 0x7f), UInt8(second & 0x7f),
        ]
        let payload = Array(available.prefix(count))
        switch status {
        case 0:
            guard systemExclusive == nil else { throw MIDIUMPCodecError.malformedSysEx(payload) }
            return [[0xf0] + payload + [0xf7]]
        case 1:
            guard systemExclusive == nil else { throw MIDIUMPCodecError.malformedSysEx(payload) }
            systemExclusive = [0xf0] + payload
            return []
        case 2:
            guard systemExclusive != nil else { throw MIDIUMPCodecError.malformedSysEx(payload) }
            systemExclusive!.append(contentsOf: payload)
            return []
        case 3:
            guard var complete = systemExclusive else { throw MIDIUMPCodecError.malformedSysEx(payload) }
            complete.append(contentsOf: payload)
            complete.append(0xf7)
            systemExclusive = nil
            return [complete]
        default:
            throw MIDIUMPCodecError.unsupportedUMP(first)
        }
    }
}
