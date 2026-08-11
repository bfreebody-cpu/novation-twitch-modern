import Foundation

public enum USBDescriptorError: Error, CustomStringConvertible, Equatable {
    case tooShort(kind: String, expected: Int, actual: Int)
    case unexpectedType(expected: UInt8, actual: UInt8)
    case malformed(offset: Int, reason: String)

    public var description: String {
        switch self {
        case let .tooShort(kind, expected, actual):
            return "\(kind) is too short: expected at least \(expected) bytes, got \(actual)"
        case let .unexpectedType(expected, actual):
            return String(format: "unexpected descriptor type 0x%02x (expected 0x%02x)", actual, expected)
        case let .malformed(offset, reason):
            return "malformed descriptor at offset \(offset): \(reason)"
        }
    }
}

public struct DeviceDescriptor: Codable, Equatable, Sendable {
    public let length: UInt8
    public let descriptorType: UInt8
    public let usbVersion: UInt16
    public let deviceClass: UInt8
    public let deviceSubclass: UInt8
    public let deviceProtocol: UInt8
    public let endpoint0MaximumPacketSize: UInt8
    public let vendorID: UInt16
    public let productID: UInt16
    public let deviceVersion: UInt16
    public let manufacturerStringIndex: UInt8
    public let productStringIndex: UInt8
    public let serialNumberStringIndex: UInt8
    public let configurationCount: UInt8
    public let rawHex: String
}

public struct GenericDescriptor: Codable, Equatable, Sendable {
    public let offset: Int
    public let length: UInt8
    public let type: UInt8
    public let typeName: String
    public let subtype: UInt8?
    public let rawHex: String
}

public struct EndpointDescriptor: Codable, Equatable, Sendable {
    public let offset: Int
    public let length: UInt8
    public let address: UInt8
    public let direction: String
    public let endpointNumber: UInt8
    public let attributes: UInt8
    public let transferType: String
    public let synchronizationType: String
    public let usageType: String
    public let maximumPacketSizeRaw: UInt16
    public let maximumPacketPayloadBytes: UInt16
    public let transactionsPerMicroframe: UInt8
    public let interval: UInt8
    public let refresh: UInt8?
    public let synchronizationAddress: UInt8?
    public let rawHex: String
}

public struct InterfaceAlternateSetting: Codable, Equatable, Sendable {
    public let offset: Int
    public let length: UInt8
    public let number: UInt8
    public let alternateSetting: UInt8
    public let declaredEndpointCount: UInt8
    public let interfaceClass: UInt8
    public let interfaceSubclass: UInt8
    public let interfaceProtocol: UInt8
    public let stringIndex: UInt8
    public var endpoints: [EndpointDescriptor]
    public var additionalDescriptors: [GenericDescriptor]
    public let rawHex: String
}

public struct ConfigurationDescriptor: Codable, Equatable, Sendable {
    public let index: Int
    public let length: UInt8
    public let descriptorType: UInt8
    public let totalLength: UInt16
    public let interfaceCount: UInt8
    public let configurationValue: UInt8
    public let stringIndex: UInt8
    public let attributes: UInt8
    public let maximumPowerMilliAmps: UInt16
    public let alternateSettings: [InterfaceAlternateSetting]
    public let unassociatedDescriptors: [GenericDescriptor]
    public let descriptorSequence: [GenericDescriptor]
    public let rawHex: String
}

public enum USBDescriptorParser {
    public static func parseDevice(_ data: Data) throws -> DeviceDescriptor {
        guard data.count >= 18 else {
            throw USBDescriptorError.tooShort(kind: "device descriptor", expected: 18, actual: data.count)
        }
        let bytes = [UInt8](data)
        guard bytes[1] == 0x01 else {
            throw USBDescriptorError.unexpectedType(expected: 0x01, actual: bytes[1])
        }
        guard bytes[0] >= 18 else {
            throw USBDescriptorError.malformed(offset: 0, reason: "bLength is \(bytes[0]), expected at least 18")
        }
        return DeviceDescriptor(
            length: bytes[0], descriptorType: bytes[1], usbVersion: word(bytes, 2),
            deviceClass: bytes[4], deviceSubclass: bytes[5], deviceProtocol: bytes[6],
            endpoint0MaximumPacketSize: bytes[7], vendorID: word(bytes, 8), productID: word(bytes, 10),
            deviceVersion: word(bytes, 12), manufacturerStringIndex: bytes[14], productStringIndex: bytes[15],
            serialNumberStringIndex: bytes[16], configurationCount: bytes[17], rawHex: hex(data.prefix(18))
        )
    }

    public static func parseConfiguration(_ data: Data, index: Int) throws -> ConfigurationDescriptor {
        guard data.count >= 9 else {
            throw USBDescriptorError.tooShort(kind: "configuration descriptor", expected: 9, actual: data.count)
        }
        let bytes = [UInt8](data)
        guard bytes[1] == 0x02 else {
            throw USBDescriptorError.unexpectedType(expected: 0x02, actual: bytes[1])
        }
        guard bytes[0] >= 9 else {
            throw USBDescriptorError.malformed(offset: 0, reason: "configuration bLength is \(bytes[0]), expected at least 9")
        }
        let totalLength = word(bytes, 2)
        guard totalLength >= 9 else {
            throw USBDescriptorError.malformed(offset: 0, reason: "wTotalLength is \(totalLength), expected at least 9")
        }
        guard Int(totalLength) <= bytes.count else {
            throw USBDescriptorError.tooShort(
                kind: "configuration descriptor tree", expected: Int(totalLength), actual: bytes.count
            )
        }

        var sequence: [GenericDescriptor] = []
        var unassociated: [GenericDescriptor] = []
        var interfaces: [InterfaceAlternateSetting] = []
        var currentInterfaceIndex: Int?
        var offset = 0

        while offset < Int(totalLength) {
            guard offset + 2 <= Int(totalLength) else {
                throw USBDescriptorError.malformed(offset: offset, reason: "descriptor header is truncated")
            }
            let length = Int(bytes[offset])
            guard length >= 2 else {
                throw USBDescriptorError.malformed(offset: offset, reason: "bLength is \(length)")
            }
            guard offset + length <= Int(totalLength) else {
                throw USBDescriptorError.malformed(offset: offset, reason: "descriptor extends beyond wTotalLength")
            }
            let raw = Data(bytes[offset..<(offset + length)])
            let generic = GenericDescriptor(
                offset: offset, length: bytes[offset], type: bytes[offset + 1],
                typeName: descriptorTypeName(bytes[offset + 1]),
                subtype: length >= 3 && [0x21, 0x24, 0x25].contains(bytes[offset + 1]) ? bytes[offset + 2] : nil,
                rawHex: hex(raw)
            )
            sequence.append(generic)

            switch bytes[offset + 1] {
            case 0x02:
                if offset != 0 {
                    unassociated.append(generic)
                }
            case 0x04:
                guard length >= 9 else {
                    throw USBDescriptorError.malformed(offset: offset, reason: "interface descriptor is shorter than 9 bytes")
                }
                interfaces.append(InterfaceAlternateSetting(
                    offset: offset, length: bytes[offset], number: bytes[offset + 2],
                    alternateSetting: bytes[offset + 3], declaredEndpointCount: bytes[offset + 4],
                    interfaceClass: bytes[offset + 5], interfaceSubclass: bytes[offset + 6],
                    interfaceProtocol: bytes[offset + 7], stringIndex: bytes[offset + 8],
                    endpoints: [], additionalDescriptors: [], rawHex: hex(raw)
                ))
                currentInterfaceIndex = interfaces.count - 1
            case 0x05:
                guard length >= 7 else {
                    throw USBDescriptorError.malformed(offset: offset, reason: "endpoint descriptor is shorter than 7 bytes")
                }
                guard let interfaceIndex = currentInterfaceIndex else {
                    unassociated.append(generic)
                    offset += length
                    continue
                }
                let attributes = bytes[offset + 3]
                let maximumPacketSize = word(bytes, offset + 4)
                interfaces[interfaceIndex].endpoints.append(EndpointDescriptor(
                    offset: offset, length: bytes[offset], address: bytes[offset + 2],
                    direction: bytes[offset + 2] & 0x80 == 0 ? "out" : "in",
                    endpointNumber: bytes[offset + 2] & 0x0f, attributes: attributes,
                    transferType: transferTypeName(attributes & 0x03),
                    synchronizationType: synchronizationTypeName((attributes >> 2) & 0x03),
                    usageType: usageTypeName((attributes >> 4) & 0x03, transferType: attributes & 0x03),
                    maximumPacketSizeRaw: maximumPacketSize,
                    maximumPacketPayloadBytes: maximumPacketSize & 0x07ff,
                    transactionsPerMicroframe: UInt8(((maximumPacketSize >> 11) & 0x03) + 1),
                    interval: bytes[offset + 6], refresh: length >= 8 ? bytes[offset + 7] : nil,
                    synchronizationAddress: length >= 9 ? bytes[offset + 8] : nil, rawHex: hex(raw)
                ))
            default:
                if let interfaceIndex = currentInterfaceIndex {
                    interfaces[interfaceIndex].additionalDescriptors.append(generic)
                } else {
                    unassociated.append(generic)
                }
            }
            offset += length
        }

        return ConfigurationDescriptor(
            index: index, length: bytes[0], descriptorType: bytes[1], totalLength: totalLength,
            interfaceCount: bytes[4], configurationValue: bytes[5], stringIndex: bytes[6],
            attributes: bytes[7], maximumPowerMilliAmps: UInt16(bytes[8]) * 2,
            alternateSettings: interfaces, unassociatedDescriptors: unassociated,
            descriptorSequence: sequence, rawHex: hex(data.prefix(Int(totalLength)))
        )
    }

    public static func hex<S: DataProtocol>(_ data: S) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func descriptorTypeName(_ type: UInt8) -> String {
        switch type {
        case 0x01: "device"
        case 0x02: "configuration"
        case 0x03: "string"
        case 0x04: "interface"
        case 0x05: "endpoint"
        case 0x0b: "interface-association"
        case 0x21: "class-specific-0x21"
        case 0x24: "class-specific-interface"
        case 0x25: "class-specific-endpoint"
        default: String(format: "unknown-0x%02x", type)
        }
    }

    private static func transferTypeName(_ value: UInt8) -> String {
        ["control", "isochronous", "bulk", "interrupt"][Int(value)]
    }

    private static func synchronizationTypeName(_ value: UInt8) -> String {
        ["none", "asynchronous", "adaptive", "synchronous"][Int(value)]
    }

    private static func usageTypeName(_ value: UInt8, transferType: UInt8) -> String {
        if transferType == 1 {
            return ["data", "feedback", "implicit-feedback-data", "reserved"][Int(value)]
        }
        if transferType == 3 {
            return ["periodic", "notification", "reserved", "reserved"][Int(value)]
        }
        return String(format: "not-applicable (bits=%u)", value)
    }
}
