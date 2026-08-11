import Foundation

public enum TwitchOutputValidationError: Error, CustomStringConvertible, Equatable {
    case emptyMessage
    case unsupportedMessage([UInt8])
    case invalidValue([UInt8])

    public var description: String {
        switch self {
        case .emptyMessage:
            "empty MIDI output message"
        case let .unsupportedMessage(bytes):
            "MIDI output is not in the documented Twitch basic-mode allowlist: \(Self.hex(bytes))"
        case let .invalidValue(bytes):
            "MIDI output has a value outside the documented range: \(Self.hex(bytes))"
        }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

/// Safety policy for M4 controller output. It deliberately accepts only output
/// identities documented for Twitch basic mode; advanced mode, global diagnostic
/// commands, SysEx, system messages, and unknown controls are rejected.
public enum TwitchBasicOutputPolicy {
    private static let deckButtonNotes: Set<UInt8> = [
        0, 3, 6, 10, 13, 16, 17, 18, 19, 22, 23, 56, 57, 58, 59,
    ]
    private static let deckMeterNotes: Set<UInt8> = [90, 94, 95]
    private static let fxButtonNotes: Set<UInt8> = [
        5, 6, 9, 10, 13, 14, 17, 18, 32, 33, 34, 35,
    ]
    private static let touchstripGuideValues: Set<UInt8> = [0, 1, 2, 3, 16, 17, 18, 19]

    public static func validate(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { throw TwitchOutputValidationError.emptyMessage }
        guard bytes.count == 3 else {
            throw TwitchOutputValidationError.unsupportedMessage(bytes)
        }
        let status = bytes[0]
        let control = bytes[1]
        let value = bytes[2]
        guard control < 0x80, value < 0x80 else {
            throw TwitchOutputValidationError.invalidValue(bytes)
        }

        if (0x97...0x9a).contains(status) {
            guard deckButtonNotes.contains(control)
                    || deckMeterNotes.contains(control)
                    || (96...127).contains(control) else {
                throw TwitchOutputValidationError.unsupportedMessage(bytes)
            }
            return
        }
        if status == 0x9b, fxButtonNotes.contains(control) {
            return
        }
        if (0xb7...0xba).contains(status), control == 21 {
            guard touchstripGuideValues.contains(value) else {
                throw TwitchOutputValidationError.invalidValue(bytes)
            }
            return
        }
        throw TwitchOutputValidationError.unsupportedMessage(bytes)
    }

    public static func validateControllerOutputEndpoint(
        address: UInt8, direction: String, transferType: String,
        maximumPacketSize: UInt16
    ) throws {
        guard address == 0x03, direction == "out", transferType == "interrupt",
              maximumPacketSize > 0, maximumPacketSize <= 1_024 else {
            throw TwitchOutputValidationError.unsupportedMessage([
                address, UInt8(truncatingIfNeeded: maximumPacketSize)
            ])
        }
    }
}

public enum MIDIUSBPacketizerError: Error, CustomStringConvertible, Equatable {
    case invalidMaximumPacketSize(Int)

    public var description: String {
        switch self {
        case let .invalidMaximumPacketSize(size):
            "invalid USB maximum packet size \(size)"
        }
    }
}

/// Converts an already reconstructed logical MIDI byte stream to USB writes.
/// Message boundaries are intentionally not preserved: bytes are packed into
/// chunks no larger than the endpoint's descriptor-derived maximum packet size.
public enum MIDIUSBPacketizer {
    public static func packets(
        messages: [[UInt8]], maximumPacketSize: Int
    ) throws -> [[UInt8]] {
        guard maximumPacketSize > 0 else {
            throw MIDIUSBPacketizerError.invalidMaximumPacketSize(maximumPacketSize)
        }
        let stream = messages.flatMap { $0 }
        guard !stream.isEmpty else { return [] }
        return stride(from: 0, to: stream.count, by: maximumPacketSize).map {
            Array(stream[$0..<min($0 + maximumPacketSize, stream.count)])
        }
    }
}

/// Pure bounded FIFO used by the USB writer. Overflow rejects the new packet;
/// it never drops or reorders an already accepted controller-state update.
public struct BoundedOutputQueue<Element> {
    public let capacity: Int
    private var storage: [Element] = []

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var remainingCapacity: Int { capacity - storage.count }

    public mutating func removeAll() { storage.removeAll(keepingCapacity: true) }

    @discardableResult
    public mutating func append(_ element: Element) -> Bool {
        guard storage.count < capacity else { return false }
        storage.append(element)
        return true
    }

    public mutating func popFirst() -> Element? {
        guard !storage.isEmpty else { return nil }
        return storage.removeFirst()
    }
}
