import Darwin
import Foundation
import IOKit
@preconcurrency import TwitchA1USB
import TwitchAudioCore
import TwitchProbeCore
import USBHostShim

private let vendorID: UInt16 = 0x1235
private let productID: UInt16 = 0x0018

enum A15Error: Error, CustomStringConvertible {
    case safety(String)
    case iokit(String, kern_return_t)

    var description: String {
        switch self {
        case let .safety(message): message
        case let .iokit(operation, status):
            "\(operation): \(String(cString: mach_error_string(status))) (0x\(String(UInt32(bitPattern: status), radix: 16)))"
        }
    }
}

struct A15Metadata: Codable {
    let schemaVersion: Int
    let milestone: String
    let startedAtUTC: String
    let hostOS: String
    let hostArchitecture: String
    let gitCommit: String
    let sampleRate: Int
    let durationSeconds: Int
    let requestedUSBFrames: Int
    let frameEvidenceRecordBytes: Int
    let payloadSampleHeaderBytes: Int
    let device: DeviceDescriptor
    let configuration: ConfigurationDescriptor
    let controllerProcess: String
    let operatorCondition: String?
    let inputPayloadSampling: String
    let safetyStatement: [String]
}

struct SecondAggregate: Codable {
    let second: Int
    let outUSBFrames: UInt64
    let outAudioFrames: UInt64
    let outBytes: UInt64
    let inUSBFrames: UInt64
    let inAudioFrames: UInt64
    let inBytes: UInt64
    let cumulativeOutAudioFrames: UInt64
    let cumulativeInAudioFrames: UInt64
    let cumulativeFrameDifference: Int64
}

struct EvidenceMetrics: Codable {
    let records: UInt64
    let requestedBytes: UInt64
    let completedBytes: UInt64
    let audioFrames: UInt64
    let lengthHistogram: [String: UInt64]
    let leadHistogram: [String: UInt64]
    let queueHorizonHistogram: [String: UInt64]
    let minimumLeadFrames: UInt64?
    let maximumLeadFrames: UInt64?
    let lateOrNonSuccessFrames: UInt64
    let shortOutputFrames: UInt64
    let nonMonotonicSequenceRecords: UInt64
    let timestampIntervals: UInt64
    let timestampIntervalMinimumNanoseconds: Double?
    let timestampIntervalMaximumNanoseconds: Double?
    let timestampIntervalMeanNanoseconds: Double?
    let timestampIntervalStdDevNanoseconds: Double?
}

struct PayloadChannelStatistics: Codable {
    let samples: UInt64
    let minimum: Int32?
    let maximum: Int32?
    let mean: Double?
    let rms: Double?
}

struct PayloadStatistics: Codable {
    let sampledPackets: UInt64
    let sampledBytes: UInt64
    let nonzeroBytes: UInt64
    let distinctByteValues: Int
    let packetLengthHistogram: [String: UInt64]
    let assumedStereoPacked24Channel1: PayloadChannelStatistics
    let assumedStereoPacked24Channel2: PayloadChannelStatistics
    let note: String
}

final class RunCapture {
    let directory: URL
    private let log: FileHandle
    private let encoder = JSONEncoder()

    init(root: URL, rate: Int) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        directory = root.appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent("\(formatter.string(from: Date()))-twitch-a1-5-\(rate)hz", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("live.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        log = try FileHandle(forWritingTo: url)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    deinit { try? log.close() }

    func note(_ value: String) {
        let line = "# \(wallTime()) \(value)\n"
        log.write(Data(line.utf8)); print(line, terminator: ""); fflush(stdout)
    }

    func write<T: Encodable>(_ value: T, name: String) throws {
        var data = try encoder.encode(value); data.append(0x0a)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func writeJSON(_ value: Any, name: String) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0a)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}

final class ConcurrentTransportResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var output: [AnyHashable: Any]?
    private(set) var input: [AnyHashable: Any]?
    private(set) var outputError: Error?
    private(set) var inputError: Error?

    func setOutput(_ value: [AnyHashable: Any]) { lock.lock(); output = value; lock.unlock() }
    func setInput(_ value: [AnyHashable: Any]) { lock.lock(); input = value; lock.unlock() }
    func setOutputError(_ error: Error) { lock.lock(); outputError = error; lock.unlock() }
    func setInputError(_ error: Error) { lock.lock(); inputError = error; lock.unlock() }
}

func wallTime() -> String { ISO8601DateFormatter().string(from: Date()) }

func commandOutput(_ executable: String, _ arguments: [String]) -> String {
    let process = Process(); let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = output; process.standardError = Pipe()
    do { try process.run(); process.waitUntilExit() } catch { return "unavailable: \(error)" }
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func prompt(_ text: String, exact: String) throws {
    print("\n\(text)\nType exactly: \(exact)"); fflush(stdout)
    guard readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) == exact else {
        throw A15Error.safety("operator confirmation not received")
    }
}

func copyProperties(_ entry: io_registry_entry_t) -> [String: Any] {
    var reference: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &reference, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let values = reference?.takeRetainedValue() as? [String: Any] else { return [:] }
    return values
}

func copyDevice() throws -> io_service_t {
    guard let matching = IOServiceMatching("IOUSBHostDevice") else {
        throw A15Error.safety("IOServiceMatching failed")
    }
    let dictionary = matching as NSMutableDictionary
    dictionary["idVendor"] = NSNumber(value: vendorID)
    dictionary["idProduct"] = NSNumber(value: productID)
    var iterator: io_iterator_t = 0
    let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
    guard status == KERN_SUCCESS else { throw A15Error.iokit("IOServiceGetMatchingServices", status) }
    defer { IOObjectRelease(iterator) }
    var matches: [io_service_t] = []
    while case let item = IOIteratorNext(iterator), item != IO_OBJECT_NULL { matches.append(item) }
    guard matches.count == 1 else {
        matches.forEach { IOObjectRelease($0) }
        throw A15Error.safety("expected exactly one 1235:0018 device; found \(matches.count)")
    }
    return matches[0]
}

func copyInterface0() throws -> io_service_t {
    let device = try copyDevice(); defer { IOObjectRelease(device) }
    var iterator: io_iterator_t = 0
    let status = IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator)
    guard status == KERN_SUCCESS else { throw A15Error.iokit("IORegistryEntryGetChildIterator", status) }
    defer { IOObjectRelease(iterator) }
    var matches: [io_service_t] = []
    while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
        let values = copyProperties(child)
        if IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
           (values["bInterfaceNumber"] as? NSNumber)?.uint8Value == 0,
           (values["idVendor"] as? NSNumber)?.uint16Value == vendorID,
           (values["idProduct"] as? NSNumber)?.uint16Value == productID {
            matches.append(child)
        } else { IOObjectRelease(child) }
    }
    guard matches.count == 1 else {
        matches.forEach { IOObjectRelease($0) }
        throw A15Error.safety("expected exactly one Twitch interface 0; found \(matches.count)")
    }
    return matches[0]
}

func registryDump() -> String {
    commandOutput("/usr/sbin/ioreg", ["-p", "IOService", "-r", "-c", "IOUSBHostInterface", "-l", "-w0"])
}

func validate(device: DeviceDescriptor, configuration: ConfigurationDescriptor,
              session: TwitchA1USBSession) throws {
    guard device.vendorID == vendorID, device.productID == productID,
          session.alternateSetting == 0 else {
        throw A15Error.safety("device identity or initial alternate differs from A1 evidence")
    }
    guard let alt = configuration.alternateSettings.first(where: { $0.number == 0 && $0.alternateSetting == 1 }),
          let out = alt.endpoints.first(where: { $0.address == 0x01 }),
          let input = alt.endpoints.first(where: { $0.address == 0x82 }),
          out.maximumPacketPayloadBytes == 588, out.interval == 1,
          input.maximumPacketPayloadBytes == 294, input.interval == 1 else {
        throw A15Error.safety("audio endpoint descriptors differ from A1 evidence")
    }
    let deviceService = try copyDevice(); defer { IOObjectRelease(deviceService) }
    let configurationValue = copyProperties(deviceService)["kUSBCurrentConfiguration"] as? NSNumber
    guard configurationValue?.intValue == 1 else { throw A15Error.safety("configuration is not 1") }
}

func controlDictionary(_ raw: [AnyHashable: Any], error: Error?) -> [String: Any] {
    let data = raw["data"] as? Data ?? Data()
    return [
        "success": (raw["success"] as? NSNumber)?.boolValue ?? false,
        "bytesTransferred": (raw["bytesTransferred"] as? NSNumber)?.intValue ?? 0,
        "dataHex": data.map { String(format: "%02x", $0) }.joined(separator: " "),
        "error": error.map(String.init(describing:)) ?? NSNull(),
    ]
}

struct MutableSecond {
    var usbFrames: UInt64 = 0
    var audioFrames: UInt64 = 0
    var bytes: UInt64 = 0
}

struct Welford {
    var count: UInt64 = 0
    var mean = 0.0
    var m2 = 0.0
    var minimum = Double.greatestFiniteMagnitude
    var maximum = -Double.greatestFiniteMagnitude
    mutating func add(_ value: Double) {
        count += 1; minimum = min(minimum, value); maximum = max(maximum, value)
        let delta = value - mean; mean += delta / Double(count); m2 += delta * (value - mean)
    }
    var stddev: Double? { count > 1 ? sqrt(m2 / Double(count - 1)) : nil }
}

func analyzeEvidence(_ url: URL, bytesPerAudioFrame: UInt64, expectedOutput: Bool,
                     seconds: Int) throws -> ([MutableSecond], EvidenceMetrics) {
    let recordSize = MemoryLayout<TwitchA1FrameEvidenceV1>.size
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count % recordSize == 0 else { throw A15Error.safety("truncated evidence file \(url.lastPathComponent)") }
    var aggregates = Array(repeating: MutableSecond(), count: seconds)
    var requestedBytes: UInt64 = 0, completedBytes: UInt64 = 0, audioFrames: UInt64 = 0
    var lengths: [String: UInt64] = [:], leads: [String: UInt64] = [:], horizons: [String: UInt64] = [:]
    var minimumLead: UInt64?, maximumLead: UInt64?
    var errors: UInt64 = 0, shorts: UInt64 = 0, nonmonotonic: UInt64 = 0
    var previousSequence: UInt64?, previousTimestamp: UInt64?
    var intervals = Welford()
    var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
    let ticksToNanoseconds = Double(timebase.numer) / Double(timebase.denom)
    let count = data.count / recordSize
    data.withUnsafeBytes { raw in
        for index in 0..<count {
            let record = raw.loadUnaligned(fromByteOffset: index * recordSize, as: TwitchA1FrameEvidenceV1.self)
            requestedBytes += UInt64(record.requestCount); completedBytes += UInt64(record.completeCount)
            audioFrames += UInt64(record.completeCount) / bytesPerAudioFrame
            lengths[String(record.completeCount), default: 0] += 1
            let lead = record.requestedFrame - record.controllerFrameAtSubmit
            leads[String(lead), default: 0] += 1
            horizons[String(record.queuedFramesAtSubmit), default: 0] += 1
            minimumLead = min(minimumLead ?? lead, lead); maximumLead = max(maximumLead ?? lead, lead)
            if record.frameStatus != kIOReturnSuccess || record.transferStatus != kIOReturnSuccess { errors += 1 }
            if expectedOutput && record.completeCount != record.requestCount { shorts += 1 }
            if let previousSequence {
                if record.sequence != previousSequence + 1 { nonmonotonic += 1 }
                if record.sequence == previousSequence + 1, let previousTimestamp {
                    intervals.add(Double(record.frameTimestamp - previousTimestamp) * ticksToNanoseconds)
                }
            }
            previousSequence = record.sequence; previousTimestamp = record.frameTimestamp
            let second = min(Int(record.sequence / 1_000), max(0, seconds - 1))
            aggregates[second].usbFrames += 1
            aggregates[second].bytes += UInt64(record.completeCount)
            aggregates[second].audioFrames += UInt64(record.completeCount) / bytesPerAudioFrame
        }
    }
    return (aggregates, EvidenceMetrics(records: UInt64(count), requestedBytes: requestedBytes,
        completedBytes: completedBytes, audioFrames: audioFrames, lengthHistogram: lengths,
        leadHistogram: leads, queueHorizonHistogram: horizons, minimumLeadFrames: minimumLead,
        maximumLeadFrames: maximumLead, lateOrNonSuccessFrames: errors, shortOutputFrames: shorts,
        nonMonotonicSequenceRecords: nonmonotonic, timestampIntervals: intervals.count,
        timestampIntervalMinimumNanoseconds: intervals.count > 0 ? intervals.minimum : nil,
        timestampIntervalMaximumNanoseconds: intervals.count > 0 ? intervals.maximum : nil,
        timestampIntervalMeanNanoseconds: intervals.count > 0 ? intervals.mean : nil,
        timestampIntervalStdDevNanoseconds: intervals.stddev))
}

struct ChannelAccumulator {
    var count: UInt64 = 0
    var minimum = Int32.max, maximum = Int32.min
    var sum = 0.0, squareSum = 0.0
    mutating func add(_ value: Int32) {
        count += 1; minimum = min(minimum, value); maximum = max(maximum, value)
        sum += Double(value); squareSum += Double(value) * Double(value)
    }
    func result() -> PayloadChannelStatistics {
        PayloadChannelStatistics(samples: count, minimum: count > 0 ? minimum : nil,
            maximum: count > 0 ? maximum : nil, mean: count > 0 ? sum / Double(count) : nil,
            rms: count > 0 ? sqrt(squareSum / Double(count)) : nil)
    }
}

func signed24(_ bytes: Data, _ offset: Int) -> Int32 {
    var value = Int32(bytes[offset]) | Int32(bytes[offset + 1]) << 8 | Int32(bytes[offset + 2]) << 16
    if value & 0x0080_0000 != 0 { value |= ~0x00ff_ffff }
    return value
}

func analyzePayloadSamples(_ url: URL) throws -> PayloadStatistics {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let headerSize = MemoryLayout<TwitchA1PayloadSampleHeaderV1>.size
    var cursor = 0, packetCount: UInt64 = 0, byteCount: UInt64 = 0, nonzero: UInt64 = 0
    var byteValues = Set<UInt8>(), lengths: [String: UInt64] = [:]
    var channels = [ChannelAccumulator(), ChannelAccumulator()]
    while cursor < data.count {
        guard cursor + headerSize <= data.count else { throw A15Error.safety("truncated payload header") }
        let header = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: cursor, as: TwitchA1PayloadSampleHeaderV1.self)
        }
        cursor += headerSize
        let length = Int(header.length)
        guard cursor + length <= data.count else { throw A15Error.safety("truncated payload body") }
        let payload = data.subdata(in: cursor..<(cursor + length)); cursor += length
        packetCount += 1; byteCount += UInt64(length); lengths[String(length), default: 0] += 1
        for byte in payload { if byte != 0 { nonzero += 1 }; byteValues.insert(byte) }
        if length % 6 == 0 {
            for offset in stride(from: 0, to: length, by: 6) {
                channels[0].add(signed24(payload, offset)); channels[1].add(signed24(payload, offset + 3))
            }
        }
    }
    return PayloadStatistics(sampledPackets: packetCount, sampledBytes: byteCount,
        nonzeroBytes: nonzero, distinctByteValues: byteValues.count, packetLengthHistogram: lengths,
        assumedStereoPacked24Channel1: channels[0].result(),
        assumedStereoPacked24Channel2: channels[1].result(),
        note: "Numeric channel statistics assume little-endian stereo packed-24 solely for analysis; A1.5 does not promote that format without a known-signal test.")
}

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
guard let sampleRate = argument("--rate").flatMap(Int.init), [44_100, 48_000].contains(sampleRate),
      let duration = argument("--duration").flatMap(Int.init), (10...1_800).contains(duration) else {
    FileHandle.standardError.write(Data("usage: twitch-a1-5 --rate 44100|48000 --duration 10...1800 [--sample-all-input] [--condition TEXT] [--repository-root PATH]\n".utf8))
    exit(2)
}
let sampleEveryInputPayload = arguments.contains("--sample-all-input")
guard !sampleEveryInputPayload || duration <= 60 else {
    FileHandle.standardError.write(Data("--sample-all-input is bounded to 60 seconds\n".utf8))
    exit(2)
}
let operatorCondition = argument("--condition")
let root = URL(fileURLWithPath: argument("--repository-root") ?? FileManager.default.currentDirectoryPath,
               isDirectory: true)
let startedAt = wallTime()
var capture: RunCapture?
var session: TwitchA1USBSession?
var signalInstalled = false
var runError: Error?
var summaryObject: [String: Any] = [:]

do {
    let recorder = try RunCapture(root: root, rate: sampleRate); capture = recorder
    recorder.note("A1.5 sustained run requested: \(sampleRate) Hz for \(duration) seconds")
    let controller = commandOutput("/usr/bin/pgrep", ["-fl", "twitch-m4"])
    guard !controller.isEmpty else { throw A15Error.safety("frozen M4 controller bridge is not running") }
    try prompt("Confirm PLAY input and its Mixxx-driven LED response work before sustained audio.", exact: "CONTROLLER VERIFIED")
    try prompt("Keep Twitch MASTER, BOOTH and HEADPHONE levels down for sustained silence.", exact: "LEVELS DOWN")
    try Data(registryDump().utf8).write(to: recorder.directory.appendingPathComponent("registry-before.txt"), options: .atomic)

    let interfaceService = try copyInterface0(); defer { IOObjectRelease(interfaceService) }
    let opened = try TwitchA1USBSession(interfaceService: interfaceService)
    session = opened
    let rawDevice = opened.deviceDescriptorData, rawConfiguration = opened.configurationDescriptorData
    let device = try USBDescriptorParser.parseDevice(rawDevice)
    let configuration = try USBDescriptorParser.parseConfiguration(rawConfiguration, index: 0)
    try validate(device: device, configuration: configuration, session: opened)
    try rawDevice.write(to: recorder.directory.appendingPathComponent("device-descriptor.bin"), options: Data.WritingOptions.atomic)
    try rawConfiguration.write(to: recorder.directory.appendingPathComponent("configuration-descriptor.bin"), options: Data.WritingOptions.atomic)
    let metadata = A15Metadata(schemaVersion: 1, milestone: "A1.5 sustained transport",
        startedAtUTC: startedAt, hostOS: commandOutput("/usr/bin/sw_vers", ["-productVersion"]) +
            " (" + commandOutput("/usr/bin/sw_vers", ["-buildVersion"]) + ")",
        hostArchitecture: commandOutput("/usr/bin/uname", ["-m"]),
        gitCommit: commandOutput("/usr/bin/git", ["rev-parse", "HEAD"]), sampleRate: sampleRate,
        durationSeconds: duration, requestedUSBFrames: duration * 1_000,
        frameEvidenceRecordBytes: MemoryLayout<TwitchA1FrameEvidenceV1>.size,
        payloadSampleHeaderBytes: MemoryLayout<TwitchA1PayloadSampleHeaderV1>.size,
        device: device, configuration: configuration, controllerProcess: controller,
        operatorCondition: operatorCondition,
        inputPayloadSampling: sampleEveryInputPayload ? "every payload" : "sparse evidence windows",
        safetyStatement: ["Interface 0 only", "Silence OUT only", "No controller endpoint access",
            "No vendor request, reset, configuration change, Core Audio, DriverKit, or legacy execution"])
    try recorder.write(metadata, name: "metadata.json")

    try opened.selectAlternateSetting(1)
    guard opened.alternateSetting == 1 else { throw A15Error.safety("alternate 1 verification failed") }
    var controlError: NSError?
    let setRaw = opened.setSampleRate(UInt(sampleRate), error: &controlError)
    let setResult = controlDictionary(setRaw, error: controlError)
    guard setResult["success"] as? Bool == true,
          setResult["bytesTransferred"] as? Int == 3 else { throw A15Error.safety("SET_CUR failed") }
    controlError = nil
    let getRaw = opened.getSampleRate(&controlError)
    let getResult = controlDictionary(getRaw, error: controlError)
    let expectedHex = sampleRate == 48_000 ? "80 bb 00" : "44 ac 00"
    guard getResult["success"] as? Bool == true,
          getResult["dataHex"] as? String == expectedHex else { throw A15Error.safety("GET_CUR mismatch") }
    recorder.note("rate initialization verified: SET_CUR/GET_CUR \(expectedHex)")

    let outURL = recorder.directory.appendingPathComponent("out-frame-evidence.bin")
    let inURL = recorder.directory.appendingPathComponent("in-frame-evidence.bin")
    let sampleURL = recorder.directory.appendingPathComponent("in-payload-samples.bin")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: inURL.path, contents: nil)
    FileManager.default.createFile(atPath: sampleURL.path, contents: nil)
    let outHandle = try FileHandle(forWritingTo: outURL), inHandle = try FileHandle(forWritingTo: inURL)
    let sampleHandle = try FileHandle(forWritingTo: sampleURL)
    defer { try? outHandle.close(); try? inHandle.close(); try? sampleHandle.close() }

    guard TwitchInstallSignalPipe() == 0 else { throw A15Error.safety("signal self-pipe failed") }
    signalInstalled = true
    opened.startSignalMonitor(withFileDescriptor: TwitchSignalReadFileDescriptor())
    let results = ConcurrentTransportResults(); let group = DispatchGroup()
    let frameCount = duration * 1_000
    recorder.note("continuous simultaneous IN/OUT starting; frame count \(frameCount), bounded scheduler horizon 64 frames, 8 batches × 8 frames")
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            let value = try opened.runSustainedSilenceEndpoint01(
                atSampleRate: UInt(sampleRate), frames: UInt(frameCount),
                recordFileDescriptor: outHandle.fileDescriptor)
            results.setOutput(value)
        } catch { results.setOutputError(error) }
        group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            let value = try opened.runSustainedInputEndpoint82(
                forFrames: UInt(frameCount), recordFileDescriptor: inHandle.fileDescriptor,
                sampleFileDescriptor: sampleHandle.fileDescriptor,
                sampleEveryPayload: sampleEveryInputPayload)
            results.setInput(value)
        } catch { results.setInputError(error) }
        group.leave()
    }
    group.wait(); opened.stopSignalMonitor()
    try outHandle.synchronize(); try inHandle.synchronize(); try sampleHandle.synchronize()
    if let error = results.outputError { throw error }; if let error = results.inputError { throw error }
    guard results.output != nil, results.input != nil else { throw A15Error.safety("missing sustained result") }
    recorder.note("continuous transport completed; analyzing compact evidence")

    let (outSeconds, outMetrics) = try analyzeEvidence(outURL, bytesPerAudioFrame: 12,
                                                       expectedOutput: true, seconds: duration)
    let (inSeconds, inMetrics) = try analyzeEvidence(inURL, bytesPerAudioFrame: 6,
                                                     expectedOutput: false, seconds: duration)
    var cumulativeOut: UInt64 = 0, cumulativeIn: UInt64 = 0, secondRows: [SecondAggregate] = []
    for second in 0..<duration {
        cumulativeOut += outSeconds[second].audioFrames; cumulativeIn += inSeconds[second].audioFrames
        secondRows.append(SecondAggregate(second: second, outUSBFrames: outSeconds[second].usbFrames,
            outAudioFrames: outSeconds[second].audioFrames, outBytes: outSeconds[second].bytes,
            inUSBFrames: inSeconds[second].usbFrames, inAudioFrames: inSeconds[second].audioFrames,
            inBytes: inSeconds[second].bytes, cumulativeOutAudioFrames: cumulativeOut,
            cumulativeInAudioFrames: cumulativeIn,
            cumulativeFrameDifference: Int64(cumulativeIn) - Int64(cumulativeOut)))
    }
    let payloadStats = try analyzePayloadSamples(sampleURL)
    try recorder.write(secondRows, name: "per-second.json")
    try recorder.write(outMetrics, name: "out-metrics.json")
    try recorder.write(inMetrics, name: "in-metrics.json")
    try recorder.write(payloadStats, name: "in-payload-statistics.json")
    summaryObject = [
        "sampleRate": sampleRate, "durationSeconds": duration,
        "setCurrent": setResult, "getCurrent": getResult,
        "outputTransport": results.output!, "inputTransport": results.input!,
        "cumulativeOutAudioFrames": cumulativeOut, "cumulativeInAudioFrames": cumulativeIn,
        "cumulativeFrameDifference": Int64(cumulativeIn) - Int64(cumulativeOut),
        "outputUSBErrors": outMetrics.lateOrNonSuccessFrames,
        "inputUSBErrors": inMetrics.lateOrNonSuccessFrames,
        "outputShortFrames": outMetrics.shortOutputFrames,
        "completed": true,
    ]
    try recorder.writeJSON(summaryObject, name: "summary.json")
    recorder.note("analysis complete; cumulative IN-OUT audio-frame difference \(Int64(cumulativeIn) - Int64(cumulativeOut))")
    try prompt("Confirm controller PLAY input and its LED response still work after sustained audio.", exact: "CONTROLLER HEALTHY")
} catch {
    runError = error; capture?.note("A1.5 run stopped: \(error)")
}

if signalInstalled { session?.stopSignalMonitor(); TwitchCloseSignalPipe() }
if let session {
    let shutdown = session.shutdown()
    summaryObject["shutdown"] = Dictionary(uniqueKeysWithValues: shutdown.map {
        (String(describing: $0.key), String(describing: $0.value))
    })
    summaryObject["completed"] = runError == nil
    if let runError { summaryObject["error"] = String(describing: runError) }
    try? capture?.writeJSON(summaryObject, name: "summary.json")
    capture?.note("shutdown: \(shutdown)")
}
if let capture { try? Data(registryDump().utf8).write(to: capture.directory.appendingPathComponent("registry-after.txt"), options: .atomic) }

if let runError {
    FileHandle.standardError.write(Data("A1.5 run failed: \(runError)\n".utf8)); exit(1)
}
print("A1.5 sustained run complete: \(capture?.directory.path ?? "unknown")")
