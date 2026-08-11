import Foundation

public struct DecodedMIDIEvent: Codable, Equatable, Sendable {
    public let monotonicNanoseconds: UInt64
    public let transferSequence: Int
    public let bytes: [UInt8]
    public let kind: String
    public let channel: Int?
    public let data1: UInt8?
    public let data2: UInt8?
    public let semantic: String
    public let controlLabel: String?

    public init(
        monotonicNanoseconds: UInt64, transferSequence: Int, bytes: [UInt8], kind: String,
        channel: Int?, data1: UInt8?, data2: UInt8?, semantic: String, controlLabel: String?
    ) {
        self.monotonicNanoseconds = monotonicNanoseconds
        self.transferSequence = transferSequence
        self.bytes = bytes
        self.kind = kind
        self.channel = channel
        self.data1 = data1
        self.data2 = data2
        self.semantic = semantic
        self.controlLabel = controlLabel
    }
}

public final class MIDIByteStreamParser: @unchecked Sendable {
    public let maximumSysExBytes: Int

    private var runningStatus: UInt8?
    private var messageStatus: UInt8?
    private var messageData: [UInt8] = []
    private var systemExclusive: [UInt8]?
    private var discardingOversizedSystemExclusive = false

    public init(maximumSysExBytes: Int = 1024) {
        self.maximumSysExBytes = max(16, maximumSysExBytes)
    }

    public func consume(
        _ bytes: [UInt8], monotonicNanoseconds: UInt64, transferSequence: Int
    ) -> [DecodedMIDIEvent] {
        var events: [DecodedMIDIEvent] = []
        for byte in bytes {
            if byte >= 0xf8 {
                events.append(event(
                    bytes: [byte], kind: "system-realtime", channel: nil, data1: nil, data2: nil,
                    semantic: realTimeName(byte), label: nil,
                    time: monotonicNanoseconds, transfer: transferSequence
                ))
                continue
            }

            if discardingOversizedSystemExclusive {
                if byte == 0xf7 { discardingOversizedSystemExclusive = false }
                continue
            }

            if var sysex = systemExclusive {
                if byte == 0xf7 {
                    sysex.append(byte)
                    systemExclusive = nil
                    events.append(event(
                        bytes: sysex, kind: "system-exclusive", channel: nil, data1: nil, data2: nil,
                        semantic: "SysEx (\(sysex.count) bytes)", label: nil,
                        time: monotonicNanoseconds, transfer: transferSequence
                    ))
                    continue
                }
                if byte & 0x80 != 0 {
                    systemExclusive = nil
                    events.append(event(
                        bytes: sysex, kind: "parser-warning", channel: nil, data1: nil, data2: nil,
                        semantic: "unterminated SysEx interrupted by status byte", label: nil,
                        time: monotonicNanoseconds, transfer: transferSequence
                    ))
                    processStatus(byte, time: monotonicNanoseconds, transfer: transferSequence, events: &events)
                    continue
                }
                sysex.append(byte)
                if sysex.count > maximumSysExBytes {
                    systemExclusive = nil
                    discardingOversizedSystemExclusive = true
                    events.append(event(
                        bytes: Array(sysex.prefix(maximumSysExBytes)), kind: "parser-warning", channel: nil,
                        data1: nil, data2: nil,
                        semantic: "SysEx exceeded \(maximumSysExBytes)-byte limit; discarded through F7",
                        label: nil, time: monotonicNanoseconds, transfer: transferSequence
                    ))
                } else {
                    systemExclusive = sysex
                }
                continue
            }

            if byte & 0x80 != 0 {
                processStatus(byte, time: monotonicNanoseconds, transfer: transferSequence, events: &events)
            } else {
                processData(byte, time: monotonicNanoseconds, transfer: transferSequence, events: &events)
            }
        }
        return events
    }

    public func incompleteStateDescription() -> String? {
        if discardingOversizedSystemExclusive { return "discarding oversized SysEx until F7" }
        if let sysex = systemExclusive { return "incomplete SysEx (\(sysex.count) bytes retained)" }
        if let status = messageStatus {
            return String(format: "incomplete message status %02x (%d data bytes retained)", status, messageData.count)
        }
        return nil
    }

    private func processStatus(
        _ status: UInt8, time: UInt64, transfer: Int, events: inout [DecodedMIDIEvent]
    ) {
        if let interruptedStatus = messageStatus {
            let expected = dataLength(for: interruptedStatus)
            events.append(event(
                bytes: [interruptedStatus] + messageData, kind: "parser-warning", channel: nil,
                data1: nil, data2: nil,
                semantic: "incomplete MIDI message interrupted by status byte "
                    + "(\(messageData.count)/\(expected) data bytes)",
                label: nil, time: time, transfer: transfer
            ))
        }
        messageData.removeAll(keepingCapacity: true)
        messageStatus = nil
        if status < 0xf0 {
            runningStatus = status
            messageStatus = status
            return
        }

        runningStatus = nil
        switch status {
        case 0xf0:
            systemExclusive = [status]
        case 0xf1, 0xf2, 0xf3:
            messageStatus = status
        case 0xf6:
            events.append(event(
                bytes: [status], kind: "system-common", channel: nil, data1: nil, data2: nil,
                semantic: "Tune Request", label: nil, time: time, transfer: transfer
            ))
        case 0xf7:
            events.append(event(
                bytes: [status], kind: "parser-warning", channel: nil, data1: nil, data2: nil,
                semantic: "unexpected SysEx end", label: nil, time: time, transfer: transfer
            ))
        default:
            events.append(event(
                bytes: [status], kind: "system-common", channel: nil, data1: nil, data2: nil,
                semantic: String(format: "undefined system status %02x", status), label: nil,
                time: time, transfer: transfer
            ))
        }
    }

    private func processData(
        _ byte: UInt8, time: UInt64, transfer: Int, events: inout [DecodedMIDIEvent]
    ) {
        if messageStatus == nil, let runningStatus {
            messageStatus = runningStatus
            messageData.removeAll(keepingCapacity: true)
        }
        guard let status = messageStatus else {
            events.append(event(
                bytes: [byte], kind: "parser-warning", channel: nil, data1: byte, data2: nil,
                semantic: "data byte without status", label: nil, time: time, transfer: transfer
            ))
            return
        }
        messageData.append(byte)
        guard messageData.count == dataLength(for: status) else { return }
        let bytes = [status] + messageData
        events.append(decode(bytes, time: time, transfer: transfer))
        messageData.removeAll(keepingCapacity: true)
        messageStatus = nil
    }

    private func decode(_ bytes: [UInt8], time: UInt64, transfer: Int) -> DecodedMIDIEvent {
        let status = bytes[0]
        if status >= 0xf0 {
            let names: [UInt8: String] = [0xf1: "MIDI Time Code Quarter Frame", 0xf2: "Song Position", 0xf3: "Song Select"]
            return event(
                bytes: bytes, kind: "system-common", channel: nil, data1: bytes.count > 1 ? bytes[1] : nil,
                data2: bytes.count > 2 ? bytes[2] : nil, semantic: names[status] ?? "System Common",
                label: nil, time: time, transfer: transfer
            )
        }
        let channel = Int(status & 0x0f) + 1
        let command = status & 0xf0
        let data1 = bytes.count > 1 ? bytes[1] : nil
        let data2 = bytes.count > 2 ? bytes[2] : nil
        let kind: String
        let semantic: String
        switch command {
        case 0x80:
            kind = "note-off"; semantic = "Note Off note \(data1!) velocity \(data2!)"
        case 0x90 where data2 == 0:
            kind = "note-off"; semantic = "Note Off (Note On velocity 0) note \(data1!)"
        case 0x90:
            kind = "note-on"; semantic = "Note On note \(data1!) velocity \(data2!)"
        case 0xb0:
            kind = "control-change"; semantic = "Control Change \(data1!) value \(data2!)"
        case 0xa0:
            kind = "polyphonic-key-pressure"; semantic = "Polyphonic Key Pressure"
        case 0xc0:
            kind = "program-change"; semantic = "Program Change \(data1!)"
        case 0xd0:
            kind = "channel-pressure"; semantic = "Channel Pressure \(data1!)"
        case 0xe0:
            kind = "pitch-bend"; semantic = "Pitch Bend"
        default:
            kind = "channel-message"; semantic = "Channel Message"
        }
        return event(
            bytes: bytes, kind: kind, channel: channel, data1: data1, data2: data2,
            semantic: semantic, label: TwitchControlLabels.label(command: command, channel: channel, data1: data1),
            time: time, transfer: transfer
        )
    }

    private func dataLength(for status: UInt8) -> Int {
        if status < 0xf0 { return (status & 0xf0 == 0xc0 || status & 0xf0 == 0xd0) ? 1 : 2 }
        switch status { case 0xf1, 0xf3: return 1; case 0xf2: return 2; default: return 0 }
    }

    private func event(
        bytes: [UInt8], kind: String, channel: Int?, data1: UInt8?, data2: UInt8?,
        semantic: String, label: String?, time: UInt64, transfer: Int
    ) -> DecodedMIDIEvent {
        DecodedMIDIEvent(
            monotonicNanoseconds: time, transferSequence: transfer, bytes: bytes, kind: kind,
            channel: channel, data1: data1, data2: data2, semantic: semantic, controlLabel: label
        )
    }

    private func realTimeName(_ byte: UInt8) -> String {
        [0xf8: "Timing Clock", 0xfa: "Start", 0xfb: "Continue", 0xfc: "Stop", 0xfe: "Active Sensing", 0xff: "System Reset"][byte]
            ?? String(format: "System Real-Time %02x", byte)
    }
}

public enum TwitchControlLabels {
    public static func label(command: UInt8, channel: Int, data1: UInt8?) -> String? {
        guard let number = data1 else { return nil }
        return TwitchBasicInputCatalog.label(command: command, channel: channel, number: number)
    }
}
