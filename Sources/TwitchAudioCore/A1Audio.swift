import Foundation

public enum A1AudioError: Error, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self { case let .invalid(message): message }
    }
}

public enum TwitchAudioFormat {
    public static let sampleRate = 48_000
    public static let channels = 4
    public static let bytesPerSample = 3
    public static let samplesPerUSBFrame = 48
    public static let bytesPerUSBFrame = channels * bytesPerSample * samplesPerUSBFrame
    public static let maximumPacketBytes = 588

    public static func validatePacket(_ packet: Data) throws {
        guard !packet.isEmpty, packet.count <= maximumPacketBytes else {
            throw A1AudioError.invalid("audio packet length \(packet.count) is outside 1...588")
        }
        guard packet.count % (channels * bytesPerSample) == 0 else {
            throw A1AudioError.invalid("audio packet length \(packet.count) is not a 12-byte sample-frame multiple")
        }
    }

    public static func samples(inUSBFrame sequence: Int, sampleRate: Int) throws -> Int {
        guard sequence >= 0, sampleRate == 44_100 || sampleRate == 48_000 else {
            throw A1AudioError.invalid("unsupported USB audio cadence")
        }
        return ((sequence + 1) * sampleRate / 1_000) - (sequence * sampleRate / 1_000)
    }

    public static func packetBytes(inUSBFrame sequence: Int, sampleRate: Int) throws -> Int {
        try samples(inUSBFrame: sequence, sampleRate: sampleRate) * channels * bytesPerSample
    }
}

public enum A1SignalGenerator {
    public static func silence(usbFrames: Int) throws -> [Data] {
        guard usbFrames > 0 else { throw A1AudioError.invalid("silence duration must be positive") }
        return Array(repeating: Data(count: TwitchAudioFormat.bytesPerUSBFrame), count: usbFrames)
    }

    /// Four-channel signed little-endian packed-24 PCM. Only `activeChannel` is nonzero.
    public static func tone(
        activeChannel: Int, usbFrames: Int = 1_000, frequency: Double = 440,
        levelDBFS: Double = -48, rampMilliseconds: Int = 10
    ) throws -> [Data] {
        guard (0..<TwitchAudioFormat.channels).contains(activeChannel) else {
            throw A1AudioError.invalid("active channel must be 0...3")
        }
        guard usbFrames > 0, frequency > 0, levelDBFS <= -48,
              rampMilliseconds >= 0, rampMilliseconds * 48 * 2 <= usbFrames * 48 else {
            throw A1AudioError.invalid("unsafe tone parameters")
        }
        let totalSamples = usbFrames * TwitchAudioFormat.samplesPerUSBFrame
        let rampSamples = rampMilliseconds * 48
        let fullScale = Double((1 << 23) - 1)
        let amplitude = fullScale * pow(10, levelDBFS / 20)
        var packets: [Data] = []
        packets.reserveCapacity(usbFrames)
        for frame in 0..<usbFrames {
            var packet = Data(capacity: TwitchAudioFormat.bytesPerUSBFrame)
            for sampleInFrame in 0..<TwitchAudioFormat.samplesPerUSBFrame {
                let sampleIndex = frame * TwitchAudioFormat.samplesPerUSBFrame + sampleInFrame
                let attack = rampSamples == 0 ? 1 : min(1, Double(sampleIndex) / Double(rampSamples))
                let remaining = totalSamples - 1 - sampleIndex
                let release = rampSamples == 0 ? 1 : min(1, Double(remaining) / Double(rampSamples))
                let envelope = min(attack, release)
                let phase = 2 * Double.pi * frequency * Double(sampleIndex) / Double(TwitchAudioFormat.sampleRate)
                let value = Int32((sin(phase) * amplitude * envelope).rounded())
                for channel in 0..<TwitchAudioFormat.channels {
                    appendPacked24(channel == activeChannel ? value : 0, to: &packet)
                }
            }
            packets.append(packet)
        }
        return packets
    }

    private static func appendPacked24(_ sample: Int32, to data: inout Data) {
        let bits = UInt32(bitPattern: sample)
        data.append(UInt8(truncatingIfNeeded: bits))
        data.append(UInt8(truncatingIfNeeded: bits >> 8))
        data.append(UInt8(truncatingIfNeeded: bits >> 16))
    }
}

public struct A1EndpointObservation: Codable, Sendable {
    public let actualLength: Int
    public let payload: [UInt8]

    public init(actualLength: Int, payload: [UInt8]) {
        self.actualLength = actualLength
        self.payload = payload
    }
}

public struct A1EndpointClassification: Codable, Equatable, Sendable {
    public let label: String
    public let observedLengths: [Int: Int]
    public let reason: String
}

public enum A1EndpointClassifier {
    public static func classify(_ observations: [A1EndpointObservation]) -> A1EndpointClassification {
        var lengths: [Int: Int] = [:]
        for item in observations { lengths[item.actualLength, default: 0] += 1 }
        let nonempty = observations.filter { $0.actualLength > 0 }
        guard !nonempty.isEmpty else {
            return .init(label: "unresolved-empty", observedLengths: lengths,
                         reason: "all completed payloads were empty")
        }
        if nonempty.allSatisfy({ $0.actualLength == 3 || $0.actualLength == 4 }) {
            return .init(label: "feedback-sized", observedLengths: lengths,
                         reason: "every nonempty payload was 3 or 4 bytes")
        }
        let audioSized = nonempty.filter {
            $0.actualLength >= 240 && $0.actualLength <= 294 && $0.actualLength % 6 == 0
        }
        if audioSized.count == nonempty.count {
            return .init(label: "audio-frame-sized", observedLengths: lengths,
                         reason: "every nonempty payload was a 240...294-byte, six-byte-frame multiple")
        }
        return .init(label: "unresolved-mixed", observedLengths: lengths,
                     reason: "payload lengths do not consistently match feedback or two-channel packed-24 audio")
    }
}
