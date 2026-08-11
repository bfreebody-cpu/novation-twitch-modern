import Foundation
import TwitchA3Core

enum Failure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { switch self { case let .assertion(message): message } }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure.assertion(message) }
}

func packed(_ samples: [Float]) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: samples.count * 3)
    let frames = samples.count / Int(TwitchA3ChannelCount)
    let written = samples.withUnsafeBufferPointer { input in
        output.withUnsafeMutableBufferPointer { destination in
            TwitchA3PackFloat32ToS24LE(input.baseAddress, frames,
                                       destination.baseAddress, destination.count)
        }
    }
    precondition(written == output.count)
    return output
}

do {
    for sequence in 0..<10_000 {
        try expect(TwitchA3SamplesForUSBFrame(UInt64(sequence), 48_000) == 48,
                   "48 kHz cadence changed at \(sequence)")
    }
    var cadence44: [Int: Int] = [:]
    var total44 = 0
    for sequence in 0..<1_000 {
        let frames = Int(TwitchA3SamplesForUSBFrame(UInt64(sequence), 44_100))
        cadence44[frames, default: 0] += 1; total44 += frames
    }
    try expect(cadence44 == [44: 900, 45: 100] && total44 == 44_100,
               "44.1 kHz cadence mismatch: \(cadence44), total \(total44)")
    try expect(TwitchA3SamplesForUSBFrame(0, 96_000) == 0,
               "unsupported sample rate accepted")

    let bytes = packed([
        -1.0, -0.5, 0.0, 0.5,
        1.0, .infinity, -.infinity, .nan,
    ])
    try expect(Array(bytes[0..<12]) == [0x00, 0x00, 0x80,
                                        0x00, 0x00, 0xc0,
                                        0x00, 0x00, 0x00,
                                        0x00, 0x00, 0x40],
               "signed packed-24 conversion or channel order mismatch")
    try expect(Array(bytes[12..<24]) == [0xff, 0xff, 0x7f,
                                         0x00, 0x00, 0x00,
                                         0x00, 0x00, 0x00,
                                         0x00, 0x00, 0x00],
               "clipping/nonfinite conversion mismatch")

    var storage = [Float](repeating: 0, count: 50 * Int(TwitchA3ChannelCount))
    var ring = TwitchA3RingBuffer()
    try expect(TwitchA3RingInitialize(&ring, &storage, 50), "ring initialization failed")
    var source = [Float]()
    for frame in 0..<52 {
        for channel in 0..<4 { source.append(Float(frame * 4 + channel) / 512.0) }
    }
    let accepted = source.withUnsafeBufferPointer {
        TwitchA3RingWrite(&ring, $0.baseAddress, 52)
    }
    try expect(accepted == 50 && ring.availableFrames == 50 && ring.overrunFrames == 2,
               "bounded ring overrun accounting failed")

    var packet48 = [UInt8](repeating: 0xaa, count: Int(TwitchA3MaximumUSBPacketBytes))
    let packet48Bytes = TwitchA3RenderUSBPacket(&ring, 48_000, 0,
                                                &packet48, packet48.count)
    try expect(packet48Bytes == 576 && ring.availableFrames == 2 && ring.underrunFrames == 0,
               "48 kHz packet render failed")
    let packet44Bytes = TwitchA3RenderUSBPacket(&ring, 44_100, 0,
                                                &packet48, packet48.count)
    try expect(packet44Bytes == 528 && ring.availableFrames == 0 && ring.underrunFrames == 42,
               "underrun silence accounting failed")
    try expect(packet48[(2 * 12)..<(44 * 12)].allSatisfy { $0 == 0 },
               "underrun frames were not deterministic silence")

    let wrapInput = [Float](repeating: 0.25, count: 48 * 4)
    let wrapAccepted = wrapInput.withUnsafeBufferPointer {
        TwitchA3RingWrite(&ring, $0.baseAddress, 48)
    }
    try expect(wrapAccepted == 48 && ring.availableFrames == 48,
               "ring wrap write failed")
    try expect(TwitchA3RenderUSBPacket(&ring, 48_000, 1,
                                      &packet48, packet48.count) == 576 && ring.availableFrames == 0,
               "ring wrap render failed")

    print("twitch-a3-tests: cadence, conversion, channel order, ring bounds, wrap and underrun passed")
} catch {
    fputs("twitch-a3-tests: FAILED: \(error)\n", stderr)
    exit(1)
}
