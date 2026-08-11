import Foundation
import IOKit

do {
            let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let service = try DeviceDiscovery.copyExactlyOneMatchingService()
            defer { IOObjectRelease(service) }

            let before = try DeviceDiscovery.snapshot(service: service, phase: "before-open")
            let acquisition = try DescriptorAcquisition(service: service)
            var destroyed = false
            defer {
                if !destroyed { acquisition.destroy() }
            }

            let descriptors = try acquisition.acquire()
            let whileOpen = try DeviceDiscovery.snapshot(service: service, phase: "while-open-after-descriptor-reads")
            acquisition.destroy()
            destroyed = true

            let postService = try DeviceDiscovery.copyExactlyOneMatchingService()
            defer { IOObjectRelease(postService) }
            let after = try DeviceDiscovery.snapshot(service: postService, phase: "after-destroy")
            let directory = try OutputWriter.write(
                acquired: descriptors, stateBefore: before, stateWhileOpen: whileOpen,
                stateAfter: after, repositoryRoot: repositoryRoot
            )
            print("Read-only Twitch descriptor capture complete: \(directory.path)")
} catch {
    FileHandle.standardError.write(Data("twitch-usb-probe: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
