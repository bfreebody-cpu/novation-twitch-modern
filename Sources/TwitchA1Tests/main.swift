import Foundation
import TwitchAudioCore

enum TestFailure: Error { case failed(String) }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

do {
    let silence = try A1SignalGenerator.silence(usbFrames: 2_000)
    try expect(silence.count == 2_000, "silence USB-frame count")
    try expect(silence.allSatisfy { $0.count == 576 && $0.allSatisfy { $0 == 0 } }, "silence layout")

    let tone = try A1SignalGenerator.tone(activeChannel: 2)
    try expect(tone.count == 1_000 && tone.allSatisfy { $0.count == 576 }, "tone layout")
    let joined = tone.reduce(into: Data()) { $0.append($1) }
    var nonzeroByChannel = [Int](repeating: 0, count: 4)
    for sample in stride(from: 0, to: joined.count, by: 12) {
        for channel in 0..<4 {
            let offset = sample + channel * 3
            if joined[offset] != 0 || joined[offset + 1] != 0 || joined[offset + 2] != 0 {
                nonzeroByChannel[channel] += 1
            }
        }
    }
    try expect(nonzeroByChannel[0] == 0 && nonzeroByChannel[1] == 0 && nonzeroByChannel[3] == 0,
               "inactive tone channels remain zero")
    try expect(nonzeroByChannel[2] > 40_000, "active tone channel contains signal")
    try expect(joined.prefix(12).allSatisfy { $0 == 0 }, "tone starts at zero ramp")
    try expect(joined.suffix(12).allSatisfy { $0 == 0 }, "tone ends at zero ramp")

    let feedback = A1EndpointClassifier.classify([
        .init(actualLength: 3, payload: [0, 0, 12]), .init(actualLength: 4, payload: [0, 0, 12, 0]),
    ])
    try expect(feedback.label == "feedback-sized", "feedback classification")
    let audio = A1EndpointClassifier.classify([
        .init(actualLength: 288, payload: []), .init(actualLength: 294, payload: []),
    ])
    try expect(audio.label == "audio-frame-sized", "audio classification")
    let mixed = A1EndpointClassifier.classify([
        .init(actualLength: 3, payload: []), .init(actualLength: 288, payload: []),
    ])
    try expect(mixed.label == "unresolved-mixed", "mixed classification")
    let cadence48 = try (0..<1_000).map {
        try TwitchAudioFormat.packetBytes(inUSBFrame: $0, sampleRate: 48_000)
    }
    try expect(Set(cadence48) == [576] && cadence48.reduce(0, +) == 576_000,
               "48 kHz packet cadence")
    let cadence441 = try (0..<1_000).map {
        try TwitchAudioFormat.packetBytes(inUSBFrame: $0, sampleRate: 44_100)
    }
    try expect(cadence441.filter { $0 == 528 }.count == 900, "44.1 kHz 44-sample packets")
    try expect(cadence441.filter { $0 == 540 }.count == 100, "44.1 kHz 45-sample packets")
    try expect(cadence441.reduce(0, +) == 44_100 * 12, "44.1 kHz exact cumulative cadence")
    print("twitch-a1-tests: all deterministic tests passed")
} catch {
    FileHandle.standardError.write(Data("twitch-a1-tests: \(error)\n".utf8))
    exit(1)
}
