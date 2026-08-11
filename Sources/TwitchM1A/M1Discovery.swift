import Foundation
import IOKit
import IOUSBHost
import TwitchProbeCore

enum M1Error: Error, CustomStringConvertible {
    case iokit(String, kern_return_t)
    case noMatch(String)
    case ambiguous(String, Int)
    case invalidEvidence(String)

    var description: String {
        switch self {
        case let .iokit(operation, code):
            return "\(operation): \(String(cString: mach_error_string(code))) (0x\(String(UInt32(bitPattern: code), radix: 16)))"
        case let .noMatch(description): return "no exact \(description) match found"
        case let .ambiguous(description, count): return "found \(count) \(description) matches; refusing ambiguity"
        case let .invalidEvidence(message): return message
        }
    }
}

enum M1Discovery {
    static let vendorID: UInt16 = 0x1235
    static let productID: UInt16 = 0x0018

    static func copyDevice() throws -> io_service_t {
        try copyExactlyOne(className: "IOUSBHostDevice", extra: [:], description: "Twitch device")
    }

    static func waitForReconnectedDevice(
        previousRegistryEntryID: UInt64, previousSessionID: String?, timeoutSeconds: Int
    ) throws -> io_service_t {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        repeat {
            do {
                let service = try copyDevice()
                let candidate = entry(service)
                let sessionChanged = previousSessionID.map {
                    candidate.properties["sessionID"] != $0
                } ?? true
                if candidate.registryEntryID != previousRegistryEntryID && sessionChanged {
                    return service
                }
                // A terminated IOService can remain visible briefly after an outstanding
                // transfer reports removal. Never count that stale identity as reconnect.
                IOObjectRelease(service)
                Thread.sleep(forTimeInterval: 0.25)
            }
            catch M1Error.noMatch { Thread.sleep(forTimeInterval: 0.25) }
        } while Date() < deadline
        throw M1Error.noMatch(
            "new Twitch registry/session identity during bounded \(timeoutSeconds)-second reconnect wait"
        )
    }

    static func copyInterface(number: UInt8) throws -> io_service_t {
        // Closing a device-level descriptor client can briefly unpublish its child
        // interfaces. Wait at most two seconds for that known lifecycle event.
        for attempt in 0..<40 {
            let device = try copyDevice()
            defer { IOObjectRelease(device) }
            var iterator: io_iterator_t = 0
            let iteratorResult = IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator)
            guard iteratorResult == KERN_SUCCESS else {
                throw M1Error.iokit("IORegistryEntryGetChildIterator", iteratorResult)
            }
            var matches: [io_service_t] = []
            while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
                let values = properties(child)
                let interfaceNumber = (values["bInterfaceNumber"] as? NSNumber)?.uint8Value
                let vendor = (values["idVendor"] as? NSNumber)?.uint16Value
                let product = (values["idProduct"] as? NSNumber)?.uint16Value
                if IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
                   interfaceNumber == number, vendor == vendorID, product == productID {
                    matches.append(child)
                } else {
                    IOObjectRelease(child)
                }
            }
            IOObjectRelease(iterator)
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 {
                matches.forEach { IOObjectRelease($0) }
                throw M1Error.ambiguous("Twitch interface \(number)", matches.count)
            }
            if attempt < 39 { Thread.sleep(forTimeInterval: 0.05) }
        }
        throw M1Error.noMatch("Twitch interface \(number) after bounded 2-second publication wait")
    }

    static func baseline(runStart: UInt64) throws -> M1Baseline {
        let service = try copyDevice()
        defer { IOObjectRelease(service) }
        let state = try snapshot(deviceService: service, phase: "before-open", runStart: runStart)
        let device = try IOUSBHostDevice(
            __ioService: service, options: [], queue: nil, interestHandler: nil
        )
        defer { device.destroy() }
        guard let devicePointer = device.deviceDescriptor else {
            throw M1Error.invalidEvidence("IOUSBHost returned no device descriptor")
        }
        let rawDevice = Data(bytes: devicePointer, count: 18)
        let parsedDevice = try USBDescriptorParser.parseDevice(rawDevice)
        guard parsedDevice.vendorID == vendorID, parsedDevice.productID == productID else {
            throw M1Error.invalidEvidence("opened descriptor did not match 1235:0018")
        }
        var raws: [Data] = []
        var parsed: [ConfigurationDescriptor] = []
        for index in 0..<Int(parsedDevice.configurationCount) {
            let pointer = try device.configurationDescriptor(with: index)
            let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
            let length = Int(bytes[2]) | Int(bytes[3]) << 8
            guard length >= 9 && length <= Int(UInt16.max) else {
                throw M1Error.invalidEvidence("invalid configuration length \(length)")
            }
            let raw = Data(bytes: pointer, count: length)
            raws.append(raw)
            parsed.append(try USBDescriptorParser.parseConfiguration(raw, index: index))
        }
        return M1Baseline(
            rawDevice: rawDevice, device: parsedDevice, rawConfigurations: raws,
            configurations: parsed, state: state
        )
    }

    static func snapshot(phase: String, runStart: UInt64) throws -> M1StateSnapshot {
        let service = try copyDevice()
        defer { IOObjectRelease(service) }
        return try snapshot(deviceService: service, phase: phase, runStart: runStart)
    }

    static func snapshot(
        deviceService: io_service_t, phase: String, runStart: UInt64
    ) throws -> M1StateSnapshot {
        M1StateSnapshot(
            phase: phase, wallTimeUTC: wallTime(),
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds - runStart,
            device: entry(deviceService), interfaces: interfaceChildren(deviceService)
        )
    }

    static func currentAlternate(interfaceNumber: UInt8) throws -> UInt8 {
        let service = try copyInterface(number: interfaceNumber)
        defer { IOObjectRelease(service) }
        let properties = properties(service)
        guard let value = properties["bAlternateSetting"] as? NSNumber else {
            throw M1Error.invalidEvidence("interface \(interfaceNumber) has no bAlternateSetting registry property")
        }
        return value.uint8Value
    }

    static func endpointIN(configuration: ConfigurationDescriptor) throws -> EndpointDescriptor {
        guard let alternate = configuration.alternateSettings.first(where: {
            $0.number == 1 && $0.alternateSetting == 0
        }), alternate.declaredEndpointCount == 2 else {
            throw M1Error.invalidEvidence("interface 1 alternate 0 endpoint inventory is missing")
        }
        guard let endpoint = alternate.endpoints.first(where: { $0.address == 0x84 }),
              endpoint.direction == "in", endpoint.transferType == "interrupt" else {
            throw M1Error.invalidEvidence("measured interrupt IN endpoint 0x84 is absent")
        }
        guard endpoint.maximumPacketPayloadBytes > 0 && endpoint.maximumPacketPayloadBytes <= 1024 else {
            throw M1Error.invalidEvidence("unsafe endpoint maximum packet size \(endpoint.maximumPacketPayloadBytes)")
        }
        return endpoint
    }

    static func endpointOUT(configuration: ConfigurationDescriptor) throws -> EndpointDescriptor {
        guard let alternate = configuration.alternateSettings.first(where: {
            $0.number == 1 && $0.alternateSetting == 0
        }), alternate.declaredEndpointCount == 2 else {
            throw M1Error.invalidEvidence("interface 1 alternate 0 endpoint inventory is missing")
        }
        guard let endpoint = alternate.endpoints.first(where: { $0.address == 0x03 }),
              endpoint.direction == "out", endpoint.transferType == "interrupt" else {
            throw M1Error.invalidEvidence("measured interrupt OUT endpoint 0x03 is absent")
        }
        do {
            try TwitchBasicOutputPolicy.validateControllerOutputEndpoint(
                address: endpoint.address, direction: endpoint.direction,
                transferType: endpoint.transferType,
                maximumPacketSize: endpoint.maximumPacketPayloadBytes
            )
        } catch {
            throw M1Error.invalidEvidence("unsafe controller output endpoint: \(error)")
        }
        return endpoint
    }

    private static func copyExactlyOne(
        className: String, extra: [String: NSNumber], description: String
    ) throws -> io_service_t {
        guard let matching = IOServiceMatching(className) else {
            throw M1Error.iokit("IOServiceMatching", kIOReturnError)
        }
        let dictionary = matching as NSMutableDictionary
        dictionary["idVendor"] = NSNumber(value: vendorID)
        dictionary["idProduct"] = NSNumber(value: productID)
        for (key, value) in extra { dictionary[key] = value }
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { throw M1Error.iokit("IOServiceGetMatchingServices", result) }
        defer { IOObjectRelease(iterator) }
        var matches: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL { matches.append(service) }
        guard !matches.isEmpty else { throw M1Error.noMatch(description) }
        guard matches.count == 1 else {
            matches.forEach { IOObjectRelease($0) }
            throw M1Error.ambiguous(description, matches.count)
        }
        return matches[0]
    }

    private static func interfaceChildren(_ device: io_registry_entry_t) -> [M1RegistryEntry] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [M1RegistryEntry] = []
        while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 { result.append(entry(child)) }
            IOObjectRelease(child)
        }
        return result.sorted { ($0.properties["bInterfaceNumber"] ?? "") < ($1.properties["bInterfaceNumber"] ?? "") }
    }

    private static func entry(_ service: io_registry_entry_t) -> M1RegistryEntry {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        var nameBuffer = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(service, &nameBuffer)
        let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let ioClass = IOObjectCopyClass(service).takeRetainedValue() as String
        var busy: UInt32 = 0
        let busyResult = IOServiceGetBusyState(service, &busy)
        let all = properties(service)
        let keys = [
            "idVendor", "idProduct", "bcdUSB", "bcdDevice", "bNumConfigurations",
            "kUSBCurrentConfiguration", "USB Address", "locationID", "sessionID", "USBSpeed",
            "UsbLinkSpeed", "UsbExclusiveOwner", "bInterfaceNumber", "bAlternateSetting",
            "bNumEndpoints", "bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol",
        ]
        var selected: [String: String] = [:]
        for key in keys where all[key] != nil { selected[key] = String(describing: all[key]!) }
        return M1RegistryEntry(
            registryEntryID: id, name: name, ioClass: ioClass,
            busyState: busyResult == KERN_SUCCESS ? busy : nil, properties: selected
        )
    }

    private static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var reference: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &reference, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = reference?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dictionary
    }

    static func wallTime() -> String { ISO8601DateFormatter().string(from: Date()) }
}
