import CryptoKit
import Darwin
import Foundation
import IOKit
@preconcurrency import TwitchA1USB
import TwitchAudioCore
import TwitchProbeCore
import USBHostShim

private let vendorID: UInt16 = 0x1235
private let productID: UInt16 = 0x0018

enum A1Error: Error, CustomStringConvertible {
    case safety(String)
    case iokit(String, kern_return_t)
    case signalShutdownRequested

    var description: String {
        switch self {
        case let .safety(message): message
        case let .iokit(operation, status):
            "\(operation): \(String(cString: mach_error_string(status))) (0x\(String(UInt32(bitPattern: status), radix: 16)))"
        case .signalShutdownRequested: "Ctrl-C shutdown smoke test requested"
        }
    }
}

struct RegistryEntry: Codable {
    let registryEntryID: UInt64
    let name: String
    let ioClass: String
    let busyState: UInt32?
    let properties: [String: String]
}

struct StateSnapshot: Codable {
    let phase: String
    let wallTimeUTC: String
    let monotonicNanoseconds: UInt64
    let device: RegistryEntry
    let interfaces: [RegistryEntry]
}

struct ControlResult: Codable {
    let operation: String
    let success: Bool
    let bytesTransferred: Int
    let request: String
    let dataHex: String
    let error: String?
}

struct IsochronousFrameRecord: Codable, Sendable {
    let phase: String
    let endpoint: String
    let sequence: Int
    let requestedUSBFrame: UInt64
    let controllerFrameAtSubmit: UInt64
    let schedulingLeadFrames: Int64
    let requestCount: Int
    let completeCount: Int
    let frameStatus: Int32
    let frameStatusText: String
    let transferStatus: Int32
    let transferStatusText: String
    let usbFrameTimestamp: UInt64
    let submittedMonotonicNanoseconds: UInt64
    let completedMonotonicNanoseconds: UInt64
    let completionCallbackDelayNanoseconds: UInt64
    let payloadHex: String
    let payloadSHA256: String
}

struct TimingSummary: Codable {
    let frameCount: Int
    let requestedBytes: Int
    let completedBytes: Int
    let lengthHistogram: [String: Int]
    let statusHistogram: [String: Int]
    let schedulingLeadMinimumFrames: Int64?
    let schedulingLeadMaximumFrames: Int64?
    let callbackDelayMinimumNanoseconds: UInt64?
    let callbackDelayMaximumNanoseconds: UInt64?
    let callbackDelayMeanNanoseconds: UInt64?
    let firstRequestedUSBFrame: UInt64?
    let lastRequestedUSBFrame: UInt64?
    let maximumPacketBytes: Int
}

struct A1Summary: Codable {
    let schemaVersion: Int
    let milestone: String
    let startedAtUTC: String
    let endedAtUTC: String
    let hostOperatingSystem: String
    let hostArchitecture: String
    let gitCommit: String
    let deviceDescriptor: DeviceDescriptor
    let configuration: ConfigurationDescriptor
    let preState: StateSnapshot
    let postState: StateSnapshot?
    let setCurrent: ControlResult?
    let getCurrent: ControlResult?
    let endpoint82Classification: A1EndpointClassification?
    let phaseTiming: [String: TimingSummary]
    let silenceSucceeded: Bool
    let tonePhaseRan: Bool
    let toneOutputMap: [String: String]
    let headphoneTestMode: Bool
    let headphoneMonitoringRoute: String?
    let operatorCondition: String?
    let controllerPreflightConfirmed: Bool
    let controllerPostSilenceConfirmed: Bool
    let controllerPostRunConfirmed: Bool
    let shutdown: [String: String]
    let errors: [String]
    let safetyStatement: [String]
}

final class CaptureWriter {
    let directory: URL
    private let logHandle: FileHandle
    private let encoder: JSONEncoder

    init(repositoryRoot: URL) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        directory = repositoryRoot.appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent("\(formatter.string(from: Date()))-twitch-a1-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("live.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        logHandle = try FileHandle(forWritingTo: log)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    deinit { try? logHandle.close() }

    func note(_ message: String) {
        let line = "# \(wallTime()) \(message)\n"
        logHandle.write(Data(line.utf8))
        print(line, terminator: "")
        fflush(stdout)
    }

    func write<T: Encodable>(_ value: T, name: String) throws {
        var data = try encoder.encode(value)
        data.append(0x0a)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func writeJSONLines<T: Encodable>(_ values: [T], name: String) throws {
        let lineEncoder = JSONEncoder()
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for value in values {
            handle.write(try lineEncoder.encode(value)); handle.write(Data([0x0a]))
        }
    }
}

final class ConcurrentSilenceResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var output: [[AnyHashable: Any]] = []
    private(set) var input: [[AnyHashable: Any]] = []
    private(set) var outputError: Error?
    private(set) var inputError: Error?

    func setOutput(_ value: [[AnyHashable: Any]]) { lock.lock(); output = value; lock.unlock() }
    func setInput(_ value: [[AnyHashable: Any]]) { lock.lock(); input = value; lock.unlock() }
    func setOutputError(_ error: Error) { lock.lock(); outputError = error; lock.unlock() }
    func setInputError(_ error: Error) { lock.lock(); inputError = error; lock.unlock() }
}

func wallTime() -> String { ISO8601DateFormatter().string(from: Date()) }

func consoleLine() throws -> String {
    var bytes: [UInt8] = []
    while true {
        var descriptors = [pollfd(
            fd: STDIN_FILENO,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )]
        let signalFD = TwitchSignalReadFileDescriptor()
        if signalFD >= 0 {
            descriptors.append(pollfd(fd: signalFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0))
        }
        let result = descriptors.withUnsafeMutableBufferPointer {
            Darwin.poll($0.baseAddress, nfds_t($0.count), -1)
        }
        if result < 0 {
            if errno == EINTR { continue }
            throw A1Error.safety("console poll failed: errno \(errno)")
        }
        if descriptors.count == 2, descriptors[1].revents != 0 {
            _ = TwitchReadPendingSignal()
            throw A1Error.signalShutdownRequested
        }
        if descriptors[0].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
            throw A1Error.signalShutdownRequested
        }
        var byte: UInt8 = 0
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        if count == 0 { throw A1Error.signalShutdownRequested }
        if count < 0 {
            if errno == EINTR { continue }
            throw A1Error.safety("console read failed: errno \(errno)")
        }
        if byte == 0x0a || byte == 0x0d { return String(decoding: bytes, as: UTF8.self) }
        if bytes.count < 4_096 { bytes.append(byte) }
    }
}

func withSignalAbortMonitor<T>(_ session: TwitchA1USBSession, _ body: () throws -> T) throws -> T {
    session.startSignalMonitor(withFileDescriptor: TwitchSignalReadFileDescriptor())
    defer { session.stopSignalMonitor() }
    return try body()
}

func commandOutput(_ executable: String, _ arguments: [String]) -> String {
    let process = Process(); let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = pipe; process.standardError = Pipe()
    do { try process.run(); process.waitUntilExit() } catch { return "unavailable: \(error)" }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func prompt(_ text: String, required: String) throws {
    print("\n\(text)\nType exactly: \(required)")
    fflush(stdout)
    guard try consoleLine().trimmingCharacters(in: .whitespacesAndNewlines) == required else {
        throw A1Error.safety("operator confirmation was not received; no further USB action permitted")
    }
}

func authorizeToneOrSkip(headphoneTest: Bool, headphoneMonitoringRoute: String?) throws -> Bool {
    let monitoringInstruction = headphoneTest
        ? "Headphones are connected at a low level with MASTER/CUE MIX set to \(headphoneMonitoringRoute ?? "centered")."
        : "Headphones must remain removed; only a low-level external output may be monitored."
    print("""

    All silence gates passed. \(monitoringInstruction)
    Type exactly AUTHORIZE -48 DBFS TONES to run them, or SKIP TONES to shut down cleanly.
    """)
    fflush(stdout)
    switch try consoleLine().trimmingCharacters(in: .whitespacesAndNewlines) {
    case "AUTHORIZE -48 DBFS TONES": return true
    case "SKIP TONES": return false
    default: throw A1Error.safety("tone authorization was not received")
    }
}

func copyProperties(_ entry: io_registry_entry_t) -> [String: Any] {
    var reference: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &reference, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let result = reference?.takeRetainedValue() as? [String: Any] else { return [:] }
    return result
}

func registryEntry(_ service: io_registry_entry_t) -> RegistryEntry {
    var id: UInt64 = 0; IORegistryEntryGetRegistryEntryID(service, &id)
    var nameBuffer = [CChar](repeating: 0, count: 128); IORegistryEntryGetName(service, &nameBuffer)
    let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    var busy: UInt32 = 0; let busyResult = IOServiceGetBusyState(service, &busy)
    let properties = copyProperties(service)
    let selectedKeys = [
        "idVendor", "idProduct", "bcdUSB", "bcdDevice", "bNumConfigurations",
        "kUSBCurrentConfiguration", "USB Address", "locationID", "sessionID", "USBSpeed",
        "UsbLinkSpeed", "UsbExclusiveOwner", "bInterfaceNumber", "bAlternateSetting",
        "bNumEndpoints", "bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol",
    ]
    var selected: [String: String] = [:]
    for key in selectedKeys where properties[key] != nil { selected[key] = String(describing: properties[key]!) }
    return RegistryEntry(registryEntryID: id, name: name,
                         ioClass: IOObjectCopyClass(service).takeRetainedValue() as String,
                         busyState: busyResult == KERN_SUCCESS ? busy : nil, properties: selected)
}

func copyExactlyOne(_ className: String, interfaceNumber: UInt8? = nil) throws -> io_service_t {
    if let interfaceNumber {
        let device = try copyExactlyOne("IOUSBHostDevice")
        defer { IOObjectRelease(device) }
        var iterator: io_iterator_t = 0
        let childResult = IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator)
        guard childResult == KERN_SUCCESS else {
            throw A1Error.iokit("IORegistryEntryGetChildIterator", childResult)
        }
        defer { IOObjectRelease(iterator) }
        var matches: [io_service_t] = []
        while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
            let properties = copyProperties(child)
            let number = (properties["bInterfaceNumber"] as? NSNumber)?.uint8Value
            let vendor = (properties["idVendor"] as? NSNumber)?.uint16Value
            let product = (properties["idProduct"] as? NSNumber)?.uint16Value
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
               number == interfaceNumber, vendor == vendorID, product == productID {
                matches.append(child)
            } else {
                IOObjectRelease(child)
            }
        }
        guard matches.count == 1 else {
            matches.forEach { IOObjectRelease($0) }
            throw A1Error.safety("expected exactly one Twitch interface \(interfaceNumber); found \(matches.count)")
        }
        return matches[0]
    }
    guard let matching = IOServiceMatching(className) else { throw A1Error.safety("IOServiceMatching failed") }
    let dictionary = matching as NSMutableDictionary
    dictionary["idVendor"] = NSNumber(value: vendorID); dictionary["idProduct"] = NSNumber(value: productID)
    var iterator: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
    guard result == KERN_SUCCESS else { throw A1Error.iokit("IOServiceGetMatchingServices", result) }
    defer { IOObjectRelease(iterator) }
    var matches: [io_service_t] = []
    while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL { matches.append(service) }
    guard matches.count == 1 else {
        matches.forEach { IOObjectRelease($0) }
        throw A1Error.safety("expected exactly one \(className) 1235:0018 match; found \(matches.count)")
    }
    return matches[0]
}

func snapshot(phase: String, runStart: UInt64) throws -> StateSnapshot {
    let device = try copyExactlyOne("IOUSBHostDevice"); defer { IOObjectRelease(device) }
    var iterator: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator) == KERN_SUCCESS else {
        throw A1Error.safety("could not enumerate Twitch interfaces")
    }
    defer { IOObjectRelease(iterator) }
    var interfaces: [RegistryEntry] = []
    while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
        if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 { interfaces.append(registryEntry(child)) }
        IOObjectRelease(child)
    }
    return StateSnapshot(phase: phase, wallTimeUTC: wallTime(),
        monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds - runStart,
        device: registryEntry(device), interfaces: interfaces.sorted {
            ($0.properties["bInterfaceNumber"] ?? "") < ($1.properties["bInterfaceNumber"] ?? "")
        })
}

func validateEvidence(device: DeviceDescriptor, configuration: ConfigurationDescriptor,
                      state: StateSnapshot, session: TwitchA1USBSession) throws {
    guard device.vendorID == vendorID, device.productID == productID else {
        throw A1Error.safety("descriptor VID/PID differs from 1235:0018")
    }
    let currentConfiguration = state.device.properties["kUSBCurrentConfiguration"]
    guard currentConfiguration == "1" || currentConfiguration == "1\n" else {
        throw A1Error.safety("current configuration is not 1: \(currentConfiguration ?? "missing")")
    }
    guard session.alternateSetting == 0 else { throw A1Error.safety("interface 0 did not begin at alternate 0") }
    guard let alternate = configuration.alternateSettings.first(where: { $0.number == 0 && $0.alternateSetting == 1 }),
          alternate.endpoints.count == 2,
          let output = alternate.endpoints.first(where: { $0.address == 0x01 }),
          let input = alternate.endpoints.first(where: { $0.address == 0x82 }),
          output.direction == "out", output.transferType == "isochronous",
          output.maximumPacketPayloadBytes == 588, output.interval == 1,
          input.direction == "in", input.transferType == "isochronous",
          input.maximumPacketPayloadBytes == 294, input.interval == 1 else {
        throw A1Error.safety("interface-0 alternate-1 descriptors differ from established evidence")
    }
}

func controlResult(operation: String, dictionary: [AnyHashable: Any], error: Error?) -> ControlResult {
    let data = dictionary["data"] as? Data ?? Data()
    return ControlResult(operation: operation,
        success: (dictionary["success"] as? NSNumber)?.boolValue ?? false,
        bytesTransferred: (dictionary["bytesTransferred"] as? NSNumber)?.intValue ?? 0,
        request: String(format: "bmRequestType=0x%02x bRequest=0x%02x wValue=0x%04x wIndex=0x%04x wLength=%d",
            (dictionary["bmRequestType"] as? NSNumber)?.uint8Value ?? 0,
            (dictionary["bRequest"] as? NSNumber)?.uint8Value ?? 0,
            (dictionary["wValue"] as? NSNumber)?.uint16Value ?? 0,
            (dictionary["wIndex"] as? NSNumber)?.uint16Value ?? 0,
            (dictionary["wLength"] as? NSNumber)?.intValue ?? 0),
        dataHex: data.map { String(format: "%02x", $0) }.joined(separator: " "),
        error: error.map(String.init(describing:)))
}

func records(_ raw: [[AnyHashable: Any]], phase: String, endpoint: UInt8) -> [IsochronousFrameRecord] {
    raw.map { item in
        let payload = item["payload"] as? Data ?? Data()
        let requested = (item["requestedFrame"] as? NSNumber)?.uint64Value ?? 0
        let submitFrame = (item["controllerFrameAtSubmit"] as? NSNumber)?.uint64Value ?? 0
        let submitted = (item["submittedMonotonicNanoseconds"] as? NSNumber)?.uint64Value ?? 0
        let completed = (item["completedMonotonicNanoseconds"] as? NSNumber)?.uint64Value ?? 0
        return IsochronousFrameRecord(phase: phase, endpoint: String(format: "0x%02x", endpoint),
            sequence: (item["sequence"] as? NSNumber)?.intValue ?? -1,
            requestedUSBFrame: requested, controllerFrameAtSubmit: submitFrame,
            schedulingLeadFrames: Int64(requested) - Int64(submitFrame),
            requestCount: (item["requestCount"] as? NSNumber)?.intValue ?? 0,
            completeCount: (item["completeCount"] as? NSNumber)?.intValue ?? 0,
            frameStatus: (item["frameStatus"] as? NSNumber)?.int32Value ?? -1,
            frameStatusText: item["frameStatusText"] as? String ?? "missing",
            transferStatus: (item["transferStatus"] as? NSNumber)?.int32Value ?? -1,
            transferStatusText: item["transferStatusText"] as? String ?? "missing",
            usbFrameTimestamp: (item["frameTimestamp"] as? NSNumber)?.uint64Value ?? 0,
            submittedMonotonicNanoseconds: submitted, completedMonotonicNanoseconds: completed,
            completionCallbackDelayNanoseconds: completed >= submitted ? completed - submitted : 0,
            payloadHex: payload.map { String(format: "%02x", $0) }.joined(separator: " "),
            payloadSHA256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
    }
}

func timing(_ records: [IsochronousFrameRecord]) -> TimingSummary {
    var lengths: [String: Int] = [:]; var statuses: [String: Int] = [:]
    for record in records {
        lengths[String(record.completeCount), default: 0] += 1
        statuses["transfer=\(record.transferStatusText),frame=\(record.frameStatusText)", default: 0] += 1
    }
    let leads = records.map(\.schedulingLeadFrames)
    let delays = records.map(\.completionCallbackDelayNanoseconds)
    return TimingSummary(frameCount: records.count,
        requestedBytes: records.reduce(0) { $0 + $1.requestCount },
        completedBytes: records.reduce(0) { $0 + $1.completeCount },
        lengthHistogram: lengths, statusHistogram: statuses,
        schedulingLeadMinimumFrames: leads.min(), schedulingLeadMaximumFrames: leads.max(),
        callbackDelayMinimumNanoseconds: delays.min(), callbackDelayMaximumNanoseconds: delays.max(),
        callbackDelayMeanNanoseconds: delays.isEmpty ? nil : delays.reduce(0, +) / UInt64(delays.count),
        firstRequestedUSBFrame: records.first?.requestedUSBFrame,
        lastRequestedUSBFrame: records.last?.requestedUSBFrame,
        maximumPacketBytes: records.map(\.completeCount).max() ?? 0)
}

let arguments = CommandLine.arguments
let headphoneTest = arguments.contains("--headphone-test")
let operatorCondition: String? = {
    guard let index = arguments.firstIndex(of: "--condition"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}()
let headphoneMonitoringRoute: String? = {
    guard let index = arguments.firstIndex(of: "--monitoring-route"), index + 1 < arguments.count else {
        return headphoneTest ? "centered" : nil
    }
    return arguments[index + 1].lowercased()
}()
if let route = headphoneMonitoringRoute, !["master", "cue", "centered"].contains(route) {
    FileHandle.standardError.write(Data("--monitoring-route must be master, cue, or centered\n".utf8))
    exit(64)
}
let shutdownSmokeTest = arguments.contains("--shutdown-smoke-test")
let activeCancellationSmokeTest = arguments.contains("--active-cancel-smoke-test")
let root: URL = {
    if let index = arguments.firstIndex(of: "--repository-root"), index + 1 < arguments.count {
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}()
let runStart = DispatchTime.now().uptimeNanoseconds
let startedAt = wallTime()
var writer: CaptureWriter?
var session: TwitchA1USBSession?
var signalMonitorInstalled = false
var preState: StateSnapshot?
var postState: StateSnapshot?
var parsedDevice: DeviceDescriptor?
var parsedConfiguration: ConfigurationDescriptor?
var setCurrent: ControlResult?
var getCurrent: ControlResult?
var classification: A1EndpointClassification?
var timingByPhase: [String: TimingSummary] = [:]
var silenceSucceeded = false
var toneRan = false
var outputMap: [String: String] = [:]
var controllerPreflight = false
var controllerPostSilence = false
var controllerPostRun = false
var shutdownResult: [String: String] = [:]
var errors: [String] = []

do {
    let capture = try CaptureWriter(repositoryRoot: root); writer = capture
    capture.note("A1 capture directory: \(capture.directory.path)")
    capture.note("frozen controller commit: b2d4bce; controller sources are not part of this executable")
    if let operatorCondition { capture.note("operator condition: \(operatorCondition)") }
    let bridgeProcesses = commandOutput("/usr/bin/pgrep", ["-fl", "twitch-m4"])
    capture.note("controller bridge process discovery: \(bridgeProcesses.isEmpty ? "none" : bridgeProcesses)")
    try prompt("Confirm the existing Twitch Modern controller bridge is running. Press and release PLAY and verify its LED responds in Mixxx.", required: "CONTROLLER VERIFIED")
    controllerPreflight = true
    if headphoneTest {
        let route = headphoneMonitoringRoute ?? "centered"
        try prompt("Headphone-output test selected. Keep BOOTH down; connect headphones at a low usable level and set MASTER/CUE MIX to \(route.uppercased()).", required: "HEADPHONE TEST SET")
        capture.note("operator authorized headphone monitoring at a low level with MASTER/CUE MIX set to \(route)")
    } else {
        try prompt("Turn MASTER, BOOTH, and HEADPHONE levels fully down. Remove headphones now. This must be true before USB audio is opened.", required: "LEVELS DOWN HEADPHONES REMOVED")
    }

    preState = try snapshot(phase: "before-interface-0-open", runStart: runStart)
    try capture.write(preState!, name: "pre-state.json")
    let interfaceService = try copyExactlyOne("IOUSBHostInterface", interfaceNumber: 0)
    defer { IOObjectRelease(interfaceService) }
    let opened = try TwitchA1USBSession(interfaceService: interfaceService)
    session = opened
    let rawDevice = opened.deviceDescriptorData
    let rawConfiguration = opened.configurationDescriptorData
    parsedDevice = try USBDescriptorParser.parseDevice(rawDevice)
    parsedConfiguration = try USBDescriptorParser.parseConfiguration(rawConfiguration, index: 0)
    try validateEvidence(device: parsedDevice!, configuration: parsedConfiguration!, state: preState!, session: opened)
    try rawDevice.write(to: capture.directory.appendingPathComponent("device-descriptor.bin"), options: Data.WritingOptions.atomic)
    try rawConfiguration.write(to: capture.directory.appendingPathComponent("configuration-descriptor.bin"), options: Data.WritingOptions.atomic)
    capture.note("preflight passed: exact 1235:0018, configuration 1, interface 0 alt 0, endpoints 0x01/0x82 match")

    try opened.selectAlternateSetting(1)
    guard opened.alternateSetting == 1 else { throw A1Error.safety("interface 0 failed to report alternate 1") }
    capture.note("interface 0 alternate 1 selected and verified")

    if shutdownSmokeTest {
        guard TwitchInstallSignalPipe() == 0 else { throw A1Error.safety("could not install signal self-pipe") }
        signalMonitorInstalled = true
        capture.note("shutdown smoke test armed at interface 0 alternate 1; no rate or endpoint request issued")
        print("Shutdown smoke test armed. Send Ctrl-C now.")
        fflush(stdout)
        _ = try consoleLine()
        throw A1Error.signalShutdownRequested
    }

    var controlError: NSError?
    let setDictionary = opened.setSampleRate48000(&controlError)
    setCurrent = controlResult(operation: "SET_CUR 48000", dictionary: setDictionary, error: controlError)
    capture.note("SET_CUR: success=\(setCurrent!.success) transferred=\(setCurrent!.bytesTransferred) data=\(setCurrent!.dataHex) error=\(setCurrent!.error ?? "none")")
    guard setCurrent!.success, setCurrent!.bytesTransferred == 3 else {
        throw A1Error.safety("48 kHz SET_CUR did not complete exactly three bytes")
    }

    controlError = nil
    let getDictionary = opened.getSampleRate(&controlError)
    getCurrent = controlResult(operation: "GET_CUR", dictionary: getDictionary, error: controlError)
    capture.note("GET_CUR: success=\(getCurrent!.success) transferred=\(getCurrent!.bytesTransferred) data=\(getCurrent!.dataHex) error=\(getCurrent!.error ?? "none")")

    guard TwitchInstallSignalPipe() == 0 else { throw A1Error.safety("could not install signal self-pipe") }
    signalMonitorInstalled = true

    if activeCancellationSmokeTest {
        capture.note("active-cancel smoke test armed: bounded endpoint-0x82 IN only; send Ctrl-C")
        print("Active-transfer cancellation test armed on endpoint 0x82. Send Ctrl-C now.")
        fflush(stdout)
        do {
            _ = try withSignalAbortMonitor(opened) {
                try opened.observeInputEndpoint82(forFrames: 60_000, requestBytes: 294, leadFrames: 64)
            }
            throw A1Error.safety("active cancellation test completed before Ctrl-C")
        } catch {
            let nsError = error as NSError
            guard nsError.code == Int(kIOReturnAborted) else { throw error }
            throw A1Error.signalShutdownRequested
        }
    }

    let rawObservation = try withSignalAbortMonitor(opened) {
        try opened.observeInputEndpoint82(forFrames: 250, requestBytes: 294, leadFrames: 64)
    }
    let observationRecords = records(rawObservation, phase: "endpoint82-full-capacity", endpoint: 0x82)
    try capture.writeJSONLines(observationRecords, name: "endpoint82-full-capacity.jsonl")
    timingByPhase["endpoint82-full-capacity"] = timing(observationRecords)
    guard observationRecords.count == 250,
          observationRecords.allSatisfy({ $0.frameStatus == kIOReturnSuccess && $0.transferStatus == kIOReturnSuccess }) else {
        throw A1Error.safety("endpoint 0x82 full-capacity observation did not complete cleanly")
    }
    classification = A1EndpointClassifier.classify(observationRecords.map {
        A1EndpointObservation(actualLength: $0.completeCount,
              payload: $0.payloadHex.split(separator: " ").compactMap { UInt8($0, radix: 16) })
    })
    capture.note("endpoint 0x82 classification: \(classification!.label), lengths \(classification!.observedLengths)")

    let silencePackets = try A1SignalGenerator.silence(usbFrames: 2_000)
    let concurrentResults = ConcurrentSilenceResults()
    let group = DispatchGroup()
    opened.startSignalMonitor(withFileDescriptor: TwitchSignalReadFileDescriptor())
    group.enter()
    DispatchQueue.global().async {
        do {
            let value = try opened.sendOutputEndpoint01Packets(silencePackets, leadFrames: 64)
            concurrentResults.setOutput(value)
        } catch { concurrentResults.setOutputError(error) }
        group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
        do {
            let value = try opened.observeInputEndpoint82(forFrames: 2_000, requestBytes: 294, leadFrames: 64)
            concurrentResults.setInput(value)
        } catch { concurrentResults.setInputError(error) }
        group.leave()
    }
    group.wait()
    opened.stopSignalMonitor()
    let silenceOut = records(concurrentResults.output, phase: "silence-out", endpoint: 0x01)
    let silenceIn = records(concurrentResults.input, phase: "silence-concurrent-in", endpoint: 0x82)
    try capture.writeJSONLines(silenceOut, name: "silence-out.jsonl")
    try capture.writeJSONLines(silenceIn, name: "silence-concurrent-in.jsonl")
    timingByPhase["silence-out"] = timing(silenceOut); timingByPhase["silence-concurrent-in"] = timing(silenceIn)
    if let silenceOutError = concurrentResults.outputError { throw silenceOutError }
    if let silenceInError = concurrentResults.inputError { throw silenceInError }
    guard silenceOut.count == 2_000, silenceIn.count == 2_000,
          silenceOut.allSatisfy({ $0.requestCount == 576 && $0.completeCount == 576 &&
              $0.frameStatus == kIOReturnSuccess && $0.transferStatus == kIOReturnSuccess }),
          silenceIn.allSatisfy({ $0.frameStatus == kIOReturnSuccess && $0.transferStatus == kIOReturnSuccess }) else {
        throw A1Error.safety("silence gate failed: incomplete, short, or errored isochronous frame")
    }
    silenceSucceeded = true
    capture.note("silence gate passed: exactly 2,000 OUT frames at 576 bytes with concurrent endpoint-0x82 observation")
    try prompt("Verify the controller still works: press PLAY and confirm the LED responds. Keep all audio levels down.", required: "CONTROLLER STILL HEALTHY")
    controllerPostSilence = true

    if try authorizeToneOrSkip(headphoneTest: headphoneTest, headphoneMonitoringRoute: headphoneMonitoringRoute) {
        var signalSpec: [[String: Any]] = []
        for channel in 0..<4 {
            signalSpec.append(["channel": channel + 1, "frequencyHz": 440, "levelDBFS": -48,
                               "durationSeconds": 1, "rampMilliseconds": 10])
        }
        try JSONSerialization.data(withJSONObject: signalSpec, options: [.prettyPrinted, .sortedKeys])
            .write(to: capture.directory.appendingPathComponent("tone-signal-specification.json"), options: .atomic)
        for channel in 0..<4 {
            var attempt = 1
            while true {
                let phase = "tone-channel-\(channel + 1)-attempt-\(attempt)"
                capture.note("starting \(phase): 440 Hz, -48 dBFS, one second, 10 ms ramps")
                let toneRaw = try withSignalAbortMonitor(opened) {
                    try opened.sendOutputEndpoint01Packets(
                        A1SignalGenerator.tone(activeChannel: channel), leadFrames: 64)
                }
                let toneRecords = records(toneRaw, phase: phase, endpoint: 0x01)
                try capture.writeJSONLines(toneRecords, name: "\(phase).jsonl")
                timingByPhase[phase] = timing(toneRecords)
                let clean = toneRecords.count == 1_000 && toneRecords.allSatisfy { record in
                    record.requestCount == 576 && record.completeCount == 576 &&
                        record.frameStatus == kIOReturnSuccess && record.transferStatus == kIOReturnSuccess
                }
                guard clean else { throw A1Error.safety("\(phase) transfer did not complete cleanly") }
                print("Report channel \(channel + 1): left, right, both, silence, other, or repeat:")
                fflush(stdout)
                let response = try consoleLine().trimmingCharacters(in: .whitespacesAndNewlines)
                if response.lowercased() == "repeat" {
                    attempt += 1
                    guard attempt <= 3 else { throw A1Error.safety("channel \(channel + 1) repeat limit reached") }
                    continue
                }
                outputMap["channel\(channel + 1)"] = response
                break
            }
            if channel < 3 {
                let silencePhase = "tone-separator-after-channel-\(channel + 1)"
                let silenceRaw = try withSignalAbortMonitor(opened) {
                    try opened.sendOutputEndpoint01Packets(
                        A1SignalGenerator.silence(usbFrames: 1_000), leadFrames: 64)
                }
                let silenceRecords = records(silenceRaw, phase: silencePhase, endpoint: 0x01)
                try capture.writeJSONLines(silenceRecords, name: "\(silencePhase).jsonl")
                timingByPhase[silencePhase] = timing(silenceRecords)
                let cleanSilence = silenceRecords.count == 1_000 && silenceRecords.allSatisfy { record in
                    record.requestCount == 576 && record.completeCount == 576 &&
                        record.frameStatus == kIOReturnSuccess && record.transferStatus == kIOReturnSuccess
                }
                guard cleanSilence else {
                    throw A1Error.safety("\(silencePhase) transfer did not complete cleanly")
                }
            }
        }
        toneRan = true
        capture.note("tone phase completed as separately drained one-second tone/silence segments")
        try prompt("Confirm controller input and one LED response still work after the tone phase.", required: "FINAL CONTROLLER HEALTHY")
        controllerPostRun = true
    } else {
        capture.note("operator skipped tone phase because no safe external monitoring output was available")
        controllerPostRun = controllerPostSilence
    }
} catch {
    if case A1Error.signalShutdownRequested = error {
        writer?.note("expected Ctrl-C shutdown smoke-test signal received")
    } else {
        errors.append(String(describing: error))
        writer?.note("A1 stopped: \(error)")
    }
}

if signalMonitorInstalled { session?.stopSignalMonitor(); TwitchCloseSignalPipe() }
if let session {
    let rawShutdown = session.shutdown()
    for (key, value) in rawShutdown { shutdownResult[String(describing: key)] = String(describing: value) }
    writer?.note("shutdown: \(shutdownResult)")
}
do {
    postState = try snapshot(phase: "after-interface-0-release", runStart: runStart)
    try writer?.write(postState!, name: "post-state.json")
} catch {
    errors.append("post-state: \(error)")
    writer?.note("post-state unavailable: \(error)")
}

if let writer, let parsedDevice, let parsedConfiguration, let preState {
    let summary = A1Summary(schemaVersion: 1, milestone: "A1 bounded userspace playback proof",
        startedAtUTC: startedAt, endedAtUTC: wallTime(),
        hostOperatingSystem: commandOutput("/usr/bin/sw_vers", ["-productVersion"]) + " (" + commandOutput("/usr/bin/sw_vers", ["-buildVersion"]) + ")",
        hostArchitecture: commandOutput("/usr/bin/uname", ["-m"]),
        gitCommit: commandOutput("/usr/bin/git", ["rev-parse", "HEAD"]),
        deviceDescriptor: parsedDevice, configuration: parsedConfiguration,
        preState: preState, postState: postState, setCurrent: setCurrent, getCurrent: getCurrent,
        endpoint82Classification: classification, phaseTiming: timingByPhase,
        silenceSucceeded: silenceSucceeded, tonePhaseRan: toneRan, toneOutputMap: outputMap,
        headphoneTestMode: headphoneTest, headphoneMonitoringRoute: headphoneMonitoringRoute,
        operatorCondition: operatorCondition,
        controllerPreflightConfirmed: controllerPreflight,
        controllerPostSilenceConfirmed: controllerPostSilence,
        controllerPostRunConfirmed: controllerPostRun,
        shutdown: shutdownResult, errors: errors,
        safetyStatement: [
            "Matched only USB VID 0x1235 PID 0x0018 interface 0",
            "No controller endpoint 0x03 or 0x84 access by twitch-a1",
            "No vendor request, reset, configuration change, Core Audio device, DriverKit, or legacy binary",
            "Only SET_INTERFACE alt 1/0, standard endpoint SET_CUR/GET_CUR, isochronous IN 0x82 and OUT 0x01",
        ])
    try? writer.write(summary, name: "a1-capture.json")
    writer.note("canonical summary written to \(writer.directory.path)/a1-capture.json")
}

if shutdownSmokeTest || activeCancellationSmokeTest {
    let restored = shutdownResult["alternateAfterRestore"] == "0"
    print(restored && errors.isEmpty ? "A1 Ctrl-C shutdown smoke test passed" : "A1 Ctrl-C shutdown smoke test failed")
    exit(restored && errors.isEmpty ? 0 : 1)
}
if !errors.isEmpty || !silenceSucceeded {
    FileHandle.standardError.write(Data("A1 INCOMPLETE: \(errors.joined(separator: "; "))\n".utf8))
    exit(1)
}
print("A1 transport phases completed; evidence: \(writer?.directory.path ?? "unknown")")
