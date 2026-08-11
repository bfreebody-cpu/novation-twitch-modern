import Foundation
import TwitchProbeCore

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case let .failed(message): message }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
        throw TestFailure.failed(message)
    } catch is USBDescriptorError {
        return
    }
}

func runTests() throws {
    let rawDevice = Data([0x12, 0x01, 0x00, 0x02, 0xff, 0x00, 0x00, 0x40,
                          0x35, 0x12, 0x18, 0x00, 0x00, 0x01, 0x01, 0x02, 0x00, 0x01])
    let device = try USBDescriptorParser.parseDevice(rawDevice)
    try expect(device.vendorID == 0x1235, "device VID decoding")
    try expect(device.productID == 0x0018, "device PID decoding")
    try expect(device.configurationCount == 1, "configuration count decoding")

    let rawConfiguration = Data([
        0x09, 0x02, 0x40, 0x00, 0x02, 0x01, 0x00, 0x80, 0xf9,
        0x09, 0x04, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00,
        0x05, 0x24, 0x01, 0xaa, 0xbb,
        0x09, 0x04, 0x00, 0x01, 0x01, 0x01, 0x02, 0x00, 0x00,
        0x09, 0x05, 0x01, 0x05, 0x40, 0x02, 0x01, 0x00, 0x82,
        0x09, 0x04, 0x01, 0x00, 0x02, 0xff, 0x00, 0x00, 0x00,
        0x07, 0x05, 0x02, 0x02, 0x40, 0x00, 0x00,
        0x07, 0x05, 0x82, 0x02, 0x40, 0x00, 0x00,
    ])
    let configuration = try USBDescriptorParser.parseConfiguration(rawConfiguration, index: 0)
    try expect(configuration.totalLength == 64, "configuration total length")
    try expect(configuration.alternateSettings.count == 3, "alternate-setting discovery")
    try expect(configuration.alternateSettings[0].additionalDescriptors.first?.type == 0x24,
               "class-specific descriptor preservation")
    let audioEndpoint = configuration.alternateSettings[1].endpoints[0]
    try expect(audioEndpoint.direction == "out", "endpoint direction")
    try expect(audioEndpoint.transferType == "isochronous", "endpoint transfer type")
    try expect(audioEndpoint.synchronizationType == "asynchronous", "endpoint synchronization")
    try expect(audioEndpoint.maximumPacketPayloadBytes == 576, "endpoint packet size")
    try expect(audioEndpoint.synchronizationAddress == 0x82, "endpoint synchronization address")
    try expect(configuration.alternateSettings[2].endpoints.map(\.direction) == ["out", "in"],
               "bulk endpoint directions")

    try expectThrows("zero-length descriptor should be rejected") {
        let raw = Data([0x09, 0x02, 0x0b, 0x00, 0x00, 0x01, 0x00, 0x80, 0x32, 0x00, 0x04])
        _ = try USBDescriptorParser.parseConfiguration(raw, index: 0)
    }
    try expectThrows("truncated descriptor tree should be rejected") {
        let raw = Data([0x09, 0x02, 0x12, 0x00, 0x01, 0x01, 0x00, 0x80, 0x32])
        _ = try USBDescriptorParser.parseConfiguration(raw, index: 0)
    }

    let midi = MIDIByteStreamParser(maximumSysExBytes: 16)
    var events = midi.consume([0x97, 0x17], monotonicNanoseconds: 1, transferSequence: 1)
    try expect(events.isEmpty, "incomplete MIDI message must span transfers")
    events = midi.consume([0x7f, 0x16, 0x00], monotonicNanoseconds: 2, transferSequence: 2)
    try expect(events.count == 2, "running status must produce two note messages")
    try expect(events[0].kind == "note-on" && events[0].controlLabel?.contains("PLAY") == true,
               "PLAY note decoding and labeling")
    try expect(events[1].kind == "note-off" && events[1].controlLabel?.contains("CUE") == true,
               "Note On velocity zero semantics under running status")

    events = midi.consume([0xb7, 0x08, 0xf8, 0x40], monotonicNanoseconds: 3, transferSequence: 3)
    try expect(events.count == 2 && events[0].kind == "system-realtime" && events[1].kind == "control-change",
               "real-time bytes must interleave without disturbing a message")
    try expect(events[1].controlLabel == "crossfader", "crossfader labeling")

    let interrupted = MIDIByteStreamParser()
    events = interrupted.consume([0xbb], monotonicNanoseconds: 3, transferSequence: 3)
    try expect(events.isEmpty, "status-only channel message must remain incomplete")
    events = interrupted.consume([0x97, 0x17, 0x7f], monotonicNanoseconds: 4, transferSequence: 4)
    try expect(events.count == 2 && events[0].kind == "parser-warning" && events[1].kind == "note-on",
               "new status must report and recover from an interrupted incomplete message")
    try expect(events[0].bytes == [0xbb] && interrupted.incompleteStateDescription() == nil,
               "interrupted-message warning must preserve bounded discarded bytes")

    events = midi.consume([0xf0, 0x00, 0x20], monotonicNanoseconds: 5, transferSequence: 5)
    try expect(events.isEmpty && midi.incompleteStateDescription()?.contains("SysEx") == true,
               "SysEx must span transfers")
    events = midi.consume([0x29, 0xf8, 0x01, 0xf7], monotonicNanoseconds: 6, transferSequence: 6)
    try expect(events.count == 2 && events[0].kind == "system-realtime" && events[1].kind == "system-exclusive",
               "interleaved real-time and completed SysEx")

    let bounded = MIDIByteStreamParser(maximumSysExBytes: 16)
    let oversized = [UInt8](repeating: 1, count: 17)
    events = bounded.consume([0xf0] + oversized + [0xf7], monotonicNanoseconds: 7, transferSequence: 7)
    try expect(events.contains(where: { $0.kind == "parser-warning" && $0.semantic.contains("exceeded") }),
               "oversized SysEx must be bounded and reported")

    let catalogParser = MIDIByteStreamParser()
    let catalogEvents = catalogParser.consume(
        [0x97, 0x50, 0x7f, 0xb8, 0x48, 0x40, 0x9b, 0x20, 0x7f, 0xb7, 0x55, 0x01],
        monotonicNanoseconds: 8, transferSequence: 8
    )
    let assessments = catalogEvents.map(TwitchBasicInputCatalog.assess)
    try expect(assessments.allSatisfy(\.documented), "documented basic-mode controls must classify")
    try expect(assessments.map(\.category) == ["browse-navigation", "eq-controls", "fx-section", "browse-navigation"],
               "basic-mode control categories")
    try expect(catalogEvents[1].controlLabel == "B high EQ", "deck/channel labeling")
    let invalidVelocity = DecodedMIDIEvent(
        monotonicNanoseconds: 9, transferSequence: 9, bytes: [0x97, 0x17, 0x40],
        kind: "note-on", channel: 8, data1: 0x17, data2: 0x40,
        semantic: "", controlLabel: nil
    )
    try expect(TwitchBasicInputCatalog.assess(invalidVelocity).issue?.contains("velocity") == true,
               "unexpected button velocity must be flagged")
    let undocumented = DecodedMIDIEvent(
        monotonicNanoseconds: 10, transferSequence: 10, bytes: [0xb7, 0x7f, 0x01],
        kind: "control-change", channel: 8, data1: 0x7f, data2: 1,
        semantic: "", controlLabel: nil
    )
    try expect(!TwitchBasicInputCatalog.assess(undocumented).documented,
               "undocumented basic-mode input must be flagged")

    let noteUMP = try MIDIUMPCodec.encode([0x97, 0x17, 0x7f])
    try expect(noteUMP == [[0x2097177f]], "MIDI 1.0 Note On UMP encoding")
    let ccUMP = try MIDIUMPCodec.encode([0xb7, 0x08, 0x40])
    try expect(ccUMP == [[0x20b70840]], "MIDI 1.0 Control Change UMP encoding")
    let realtimeUMP = try MIDIUMPCodec.encode([0xf8])
    try expect(realtimeUMP == [[0x10f80000]], "system real-time UMP encoding")

    let umpDecoder = MIDIUMPStreamDecoder()
    let noteRoundTrip = try umpDecoder.consume(words: noteUMP[0])
    try expect(noteRoundTrip == [[0x97, 0x17, 0x7f]],
               "channel-voice UMP round trip")
    let realtimeRoundTrip = try umpDecoder.consume(words: realtimeUMP[0])
    try expect(realtimeRoundTrip == [[0xf8]],
               "system real-time UMP round trip")

    let longSysEx: [UInt8] = [0xf0, 0x00, 0x20, 0x29, 0x01, 0x02, 0x03, 0x04, 0xf7]
    let sysExUMP = try MIDIUMPCodec.encode(longSysEx)
    try expect(sysExUMP.count == 2 && sysExUMP.allSatisfy { $0.count == 2 },
               "spanning SysEx must use bounded 64-bit UMP chunks")
    let sysExDecoder = MIDIUMPStreamDecoder()
    let decodedSysEx = try sysExUMP.flatMap { try sysExDecoder.consume(words: $0) }
    try expect(decodedSysEx == [longSysEx], "spanning SysEx UMP round trip")

    let runningBoundary = MIDIByteStreamParser()
    let runningEvents = runningBoundary.consume(
        [0x97, 0x17, 0x7f, 0x16, 0x00], monotonicNanoseconds: 11, transferSequence: 11
    )
    let runningUMP = try runningEvents.flatMap { try MIDIUMPCodec.encode($0.bytes) }
    let runningDecoder = MIDIUMPStreamDecoder()
    let reconstructed = try runningUMP.flatMap { try runningDecoder.consume(words: $0) }
    try expect(reconstructed == [[0x97, 0x17, 0x7f], [0x97, 0x16, 0x00]],
               "running status must publish reconstructed logical messages")

    try TwitchBasicOutputPolicy.validate([0x97, 23, 127])
    try TwitchBasicOutputPolicy.validate([0x98, 22, 15])
    try TwitchBasicOutputPolicy.validate([0x97, 96, 79])
    try TwitchBasicOutputPolicy.validate([0x9b, 32, 16])
    try TwitchBasicOutputPolicy.validate([0xb8, 21, 19])
    do {
        try TwitchBasicOutputPolicy.validate([0xb7, 0, 0x6f])
        throw TestFailure.failed("advanced-mode command must be rejected")
    } catch is TwitchOutputValidationError {}
    do {
        try TwitchBasicOutputPolicy.validate([0x9b, 28, 16])
        throw TestFailure.failed("non-controllable basic FX PARAMS LED must be rejected")
    } catch is TwitchOutputValidationError {}
    do {
        try TwitchBasicOutputPolicy.validate([0xf0, 0, 0x20, 0x29, 0xf7])
        throw TestFailure.failed("SysEx output must be rejected in M4 basic mode")
    } catch is TwitchOutputValidationError {}

    let outputPackets = try MIDIUSBPacketizer.packets(
        messages: [[0x97, 23, 127], [0x98, 22, 15], [0x97, 96, 79]],
        maximumPacketSize: 8
    )
    try expect(outputPackets == [
        [0x97, 23, 127, 0x98, 22, 15, 0x97, 96], [79],
    ], "USB output must pack a byte stream without preserving MIDI message boundaries")
    try expect(outputPackets.allSatisfy { $0.count <= 8 },
               "USB output packets must respect descriptor maximum packet size")

    var boundedQueue = BoundedOutputQueue<[UInt8]>(capacity: 2)
    try expect(boundedQueue.append([1]), "bounded queue first append")
    try expect(boundedQueue.append([2]), "bounded queue second append")
    try expect(!boundedQueue.append([3]), "bounded queue must reject overflow")
    try expect(boundedQueue.popFirst() == [1] && boundedQueue.popFirst() == [2],
               "bounded queue must preserve accepted order")

    try TwitchBasicOutputPolicy.validateControllerOutputEndpoint(
        address: 0x03, direction: "out", transferType: "interrupt", maximumPacketSize: 8
    )
    for forbiddenAddress: UInt8 in [0x01, 0x82, 0x84] {
        do {
            try TwitchBasicOutputPolicy.validateControllerOutputEndpoint(
                address: forbiddenAddress,
                direction: forbiddenAddress & 0x80 == 0 ? "out" : "in",
                transferType: forbiddenAddress == 0x01 || forbiddenAddress == 0x82
                    ? "isochronous" : "interrupt",
                maximumPacketSize: 8
            )
            throw TestFailure.failed(
                String(format: "forbidden USB output endpoint 0x%02x was accepted", forbiddenAddress)
            )
        } catch is TwitchOutputValidationError {}
    }
}

do {
    try runTests()
    print("All deterministic USB descriptor, MIDI input/output, and control-catalog tests passed.")
} catch {
    FileHandle.standardError.write(Data("Parser test failure: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
