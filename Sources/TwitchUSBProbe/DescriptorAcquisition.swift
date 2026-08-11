import Foundation
import IOUSBHost
import TwitchProbeCore

enum AcquisitionError: Error, CustomStringConvertible {
    case missingDeviceDescriptor
    case wrongDevice(vendorID: UInt16, productID: UInt16)
    case unreasonableConfigurationLength(index: Int, length: Int)

    var description: String {
        switch self {
        case .missingDeviceDescriptor:
            return "IOUSBHost returned no device descriptor"
        case let .wrongDevice(vendorID, productID):
            return String(format: "matched service descriptor is %04x:%04x; refusing to continue", vendorID, productID)
        case let .unreasonableConfigurationLength(index, length):
            return "configuration \(index) reported an invalid total length of \(length)"
        }
    }
}

final class DescriptorAcquisition {
    let device: IOUSBHostDevice

    init(service: io_service_t) throws {
        // No capture/seize option is requested. IOUSBHost still creates an exclusive user client.
        device = try IOUSBHostDevice(
            __ioService: service,
            options: [],
            queue: nil,
            interestHandler: nil
        )
    }

    func acquire() throws -> AcquiredDescriptors {
        guard let pointer = device.deviceDescriptor else {
            throw AcquisitionError.missingDeviceDescriptor
        }
        let rawDevice = Data(bytes: pointer, count: 18)
        let parsedDevice = try USBDescriptorParser.parseDevice(rawDevice)
        guard parsedDevice.vendorID == DeviceDiscovery.vendorID,
              parsedDevice.productID == DeviceDiscovery.productID else {
            throw AcquisitionError.wrongDevice(
                vendorID: parsedDevice.vendorID, productID: parsedDevice.productID
            )
        }

        var rawConfigurations: [Data] = []
        var parsedConfigurations: [ConfigurationDescriptor] = []
        for index in 0..<Int(parsedDevice.configurationCount) {
            let configurationPointer = try device.configurationDescriptor(with: index)
            let header = UnsafeRawPointer(configurationPointer).assumingMemoryBound(to: UInt8.self)
            let totalLength = Int(header[2]) | (Int(header[3]) << 8)
            guard totalLength >= 9 && totalLength <= Int(UInt16.max) else {
                throw AcquisitionError.unreasonableConfigurationLength(index: index, length: totalLength)
            }
            let raw = Data(bytes: configurationPointer, count: totalLength)
            rawConfigurations.append(raw)
            parsedConfigurations.append(try USBDescriptorParser.parseConfiguration(raw, index: index))
        }
        return AcquiredDescriptors(
            rawDevice: rawDevice, parsedDevice: parsedDevice,
            rawConfigurations: rawConfigurations, parsedConfigurations: parsedConfigurations
        )
    }

    func destroy() {
        device.destroy()
    }
}
