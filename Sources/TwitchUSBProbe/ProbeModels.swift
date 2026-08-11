import Foundation
import TwitchProbeCore

struct RegistryEntrySnapshot: Codable {
    let registryEntryID: UInt64
    let name: String
    let ioClass: String
    let busyState: UInt32?
    let properties: [String: String]
}

struct DeviceStateSnapshot: Codable {
    let phase: String
    let capturedAtUTC: String
    let device: RegistryEntrySnapshot
    let interfaces: [RegistryEntrySnapshot]
}

struct ProbeMetadata: Codable {
    let schemaVersion: Int
    let probeVersion: String
    let capturedAtUTC: String
    let hostOperatingSystem: String
    let hostArchitecture: String
    let usbAPI: String
    let requestedVendorID: String
    let requestedProductID: String
    let permittedUSBRequests: [String]
    let deliberatelyExcludedOperations: [String]
}

struct RawDescriptorFile: Codable {
    let kind: String
    let index: Int?
    let binaryFile: String
    let hexFile: String
    let byteCount: Int
    let sha256: String
}

struct ProbeCapture: Codable {
    let metadata: ProbeMetadata
    let deviceDescriptor: DeviceDescriptor
    let configurations: [ConfigurationDescriptor]
    let rawDescriptorFiles: [RawDescriptorFile]
    let stateBeforeOpen: DeviceStateSnapshot
    let stateWhileOpenAfterReads: DeviceStateSnapshot
    let stateAfterDestroy: DeviceStateSnapshot
}

struct AcquiredDescriptors {
    let rawDevice: Data
    let parsedDevice: DeviceDescriptor
    let rawConfigurations: [Data]
    let parsedConfigurations: [ConfigurationDescriptor]
}
