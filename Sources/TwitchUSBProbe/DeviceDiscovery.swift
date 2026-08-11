import Foundation
import IOKit
import IOKit.usb

enum DiscoveryError: Error, CustomStringConvertible {
    case iokit(operation: String, code: kern_return_t)
    case notFound
    case ambiguous(count: Int)
    case disappeared

    var description: String {
        switch self {
        case let .iokit(operation, code):
            return "\(operation) failed: \(String(cString: mach_error_string(code))) (0x\(String(code, radix: 16)))"
        case .notFound:
            return "no IOUSBHostDevice exactly matching VID 0x1235 and PID 0x0018 was found"
        case let .ambiguous(count):
            return "found \(count) matching Twitch devices; refusing to select one ambiguously"
        case .disappeared:
            return "the matched Twitch disappeared before the post-inspection state snapshot"
        }
    }
}

enum DeviceDiscovery {
    static let vendorID: UInt16 = 0x1235
    static let productID: UInt16 = 0x0018

    static func copyExactlyOneMatchingService() throws -> io_service_t {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else {
            throw DiscoveryError.iokit(operation: "IOServiceMatching", code: kIOReturnError)
        }
        let dictionary = matching as NSMutableDictionary
        dictionary["idVendor"] = NSNumber(value: vendorID)
        dictionary["idProduct"] = NSNumber(value: productID)

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            throw DiscoveryError.iokit(operation: "IOServiceGetMatchingServices", code: result)
        }
        defer { IOObjectRelease(iterator) }

        var matches: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            matches.append(service)
        }
        guard !matches.isEmpty else { throw DiscoveryError.notFound }
        guard matches.count == 1 else {
            for service in matches { IOObjectRelease(service) }
            throw DiscoveryError.ambiguous(count: matches.count)
        }
        return matches[0]
    }

    static func snapshot(service: io_service_t, phase: String) throws -> DeviceStateSnapshot {
        DeviceStateSnapshot(
            phase: phase,
            capturedAtUTC: ISO8601DateFormatter().string(from: Date()),
            device: entrySnapshot(service),
            interfaces: childInterfaceSnapshots(service)
        )
    }

    private static func childInterfaceSnapshots(_ service: io_service_t) -> [RegistryEntrySnapshot] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var interfaces: [RegistryEntrySnapshot] = []
        while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 {
                interfaces.append(entrySnapshot(child))
            }
        }
        return interfaces.sorted {
            ($0.properties["bInterfaceNumber"] ?? "") < ($1.properties["bInterfaceNumber"] ?? "")
        }
    }

    private static func entrySnapshot(_ entry: io_registry_entry_t) -> RegistryEntrySnapshot {
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &entryID)

        var nameBuffer = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &nameBuffer)
        let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let ioClass = (IOObjectCopyClass(entry).takeRetainedValue() as String)

        var busy: UInt32 = 0
        let busyResult = IOServiceGetBusyState(entry, &busy)

        var propertiesReference: Unmanaged<CFMutableDictionary>?
        let propertiesResult = IORegistryEntryCreateCFProperties(
            entry, &propertiesReference, kCFAllocatorDefault, 0
        )
        var formatted: [String: String] = [:]
        if propertiesResult == KERN_SUCCESS,
           let properties = propertiesReference?.takeRetainedValue() as? [String: Any] {
            let selectedKeys = [
                "idVendor", "idProduct", "bcdUSB", "bcdDevice", "bDeviceClass", "bDeviceSubClass",
                "bDeviceProtocol", "bNumConfigurations", "kUSBCurrentConfiguration", "USB Address",
                "kUSBAddress", "locationID", "sessionID", "USBSpeed", "UsbLinkSpeed", "USB Product Name",
                "kUSBVendorString", "kUSBProductString", "kUSBSerialNumberString", "UsbExclusiveOwner",
                "bInterfaceNumber", "bAlternateSetting", "bNumEndpoints", "bInterfaceClass",
                "bInterfaceSubClass", "bInterfaceProtocol", "iInterface", "IOUserClientClass",
                "IOCFPlugInTypes", "IOProviderClass",
            ]
            for key in selectedKeys {
                if let value = properties[key] {
                    formatted[key] = formatProperty(value)
                }
            }
        }
        return RegistryEntrySnapshot(
            registryEntryID: entryID, name: name, ioClass: ioClass,
            busyState: busyResult == KERN_SUCCESS ? busy : nil, properties: formatted
        )
    }

    private static func formatProperty(_ value: Any) -> String {
        if let data = value as? Data {
            return data.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
        if let dictionary = value as? [AnyHashable: Any] {
            return dictionary
                .map { "\($0.key)=\(formatProperty($0.value))" }
                .sorted().joined(separator: ", ")
        }
        if let array = value as? [Any] {
            return "[" + array.map(formatProperty).joined(separator: ", ") + "]"
        }
        return String(describing: value)
    }
}
