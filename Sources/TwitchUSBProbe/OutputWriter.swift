import Foundation
import CryptoKit
import TwitchProbeCore

enum OutputWriter {
    static func write(
        acquired: AcquiredDescriptors,
        stateBefore: DeviceStateSnapshot,
        stateWhileOpen: DeviceStateSnapshot,
        stateAfter: DeviceStateSnapshot,
        repositoryRoot: URL
    ) throws -> URL {
        let timestamp = captureDirectoryTimestamp(Date())
        let captureDirectory = repositoryRoot
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent("\(timestamp)-twitch-1235-0018", isDirectory: true)
        try FileManager.default.createDirectory(
            at: captureDirectory, withIntermediateDirectories: true
        )

        var rawFiles: [RawDescriptorFile] = []
        try writeRaw(
            acquired.rawDevice, kind: "device", index: nil,
            baseName: "device-descriptor", directory: captureDirectory, records: &rawFiles
        )
        for (index, data) in acquired.rawConfigurations.enumerated() {
            try writeRaw(
                data, kind: "configuration", index: index,
                baseName: "configuration-\(index)-descriptor-tree",
                directory: captureDirectory, records: &rawFiles
            )
        }

        let metadata = ProbeMetadata(
            schemaVersion: 1,
            probeVersion: "M0.5-1",
            capturedAtUTC: ISO8601DateFormatter().string(from: Date()),
            hostOperatingSystem: processOutput("/usr/bin/sw_vers", []),
            hostArchitecture: processOutput("/usr/bin/uname", ["-m"]),
            usbAPI: "IOUSBHost.framework / IOUSBHostDevice (empty options; no capture/seize)",
            requestedVendorID: "0x1235", requestedProductID: "0x0018",
            permittedUSBRequests: ["standard GET_DESCRIPTOR, issued by IOUSBHost only as needed"],
            deliberatelyExcludedOperations: [
                "SET_INTERFACE", "SET_CONFIGURATION", "device reset", "vendor-specific control requests",
                "controller endpoint transfers", "audio isochronous transfers", "MIDI", "LED output",
                "Novation interface-0 activation transition", "capture/seize option",
            ]
        )
        let capture = ProbeCapture(
            metadata: metadata, deviceDescriptor: acquired.parsedDevice,
            configurations: acquired.parsedConfigurations, rawDescriptorFiles: rawFiles,
            stateBeforeOpen: stateBefore, stateWhileOpenAfterReads: stateWhileOpen,
            stateAfterDestroy: stateAfter
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(capture).write(to: captureDirectory.appendingPathComponent("capture.json"))
        try report(capture).write(
            to: captureDirectory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8
        )
        return captureDirectory
    }

    private static func writeRaw(
        _ data: Data, kind: String, index: Int?, baseName: String, directory: URL,
        records: inout [RawDescriptorFile]
    ) throws {
        let binaryName = "\(baseName).bin"
        let hexName = "\(baseName).hex.txt"
        try data.write(to: directory.appendingPathComponent(binaryName))
        let lines = stride(from: 0, to: data.count, by: 16).map { offset in
            let end = min(offset + 16, data.count)
            return String(format: "%04x  ", offset) + USBDescriptorParser.hex(data[offset..<end])
        }.joined(separator: "\n") + "\n"
        try lines.write(to: directory.appendingPathComponent(hexName), atomically: true, encoding: .utf8)
        records.append(RawDescriptorFile(
            kind: kind, index: index, binaryFile: binaryName, hexFile: hexName, byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        ))
    }

    private static func report(_ capture: ProbeCapture) -> String {
        let device = capture.deviceDescriptor
        var text = """
        # Novation Twitch read-only USB descriptor capture

        - Captured: \(capture.metadata.capturedAtUTC)
        - Host: macOS \(capture.metadata.hostOperatingSystem.replacingOccurrences(of: "\n", with: " ")) (\(capture.metadata.hostArchitecture))
        - API: \(capture.metadata.usbAPI)
        - Device: \(hex(device.vendorID, width: 4)):\(hex(device.productID, width: 4)), bcdDevice \(hex(device.deviceVersion, width: 4)), USB \(hex(device.usbVersion, width: 4))
        - Configurations: \(device.configurationCount)

        The run requested no capture/seize option. It performed descriptor acquisition only; see `capture.json` for the before/open/after registry snapshots and complete decoded data.

        """
        for configuration in capture.configurations {
            text += "## Configuration \(configuration.index)\n\n"
            text += "Value \(configuration.configurationValue), total length \(configuration.totalLength), declared interfaces \(configuration.interfaceCount), max power \(configuration.maximumPowerMilliAmps) mA.\n\n"
            for interface in configuration.alternateSettings {
                text += "### Interface \(interface.number), alternate \(interface.alternateSetting)\n\n"
                text += "Class \(hex(interface.interfaceClass, width: 2))/\(hex(interface.interfaceSubclass, width: 2))/\(hex(interface.interfaceProtocol, width: 2)); declared endpoints \(interface.declaredEndpointCount).\n\n"
                for endpoint in interface.endpoints {
                    let syncAddress = endpoint.synchronizationAddress.map { hex($0, width: 2) } ?? "not present"
                    text += "- Endpoint \(hex(endpoint.address, width: 2)): \(endpoint.direction), \(endpoint.transferType), synchronization \(endpoint.synchronizationType), usage \(endpoint.usageType), max packet \(endpoint.maximumPacketPayloadBytes) bytes (raw \(hex(endpoint.maximumPacketSizeRaw, width: 4))), interval \(endpoint.interval), synchronization address \(syncAddress)\n"
                }
                if interface.endpoints.isEmpty { text += "- No endpoints.\n" }
                if !interface.additionalDescriptors.isEmpty {
                    text += "\nAdditional descriptors: " + interface.additionalDescriptors.map {
                        "\($0.typeName) at offset \($0.offset) (`\($0.rawHex)`)"
                    }.joined(separator: "; ") + ".\n"
                }
                text += "\n"
            }
        }
        return text
    }

    private static func hex<T: FixedWidthInteger>(_ value: T, width: Int) -> String {
        "0x" + String(value, radix: 16).leftPadded(to: width, with: "0")
    }

    private static func captureDirectoryTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }

    private static func processOutput(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        } catch {
            return "unavailable: \(error)"
        }
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        String(repeating: String(character), count: max(0, length - count)) + self
    }
}
