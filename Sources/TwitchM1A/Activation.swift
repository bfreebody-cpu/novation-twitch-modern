import Foundation
import IOKit
import IOUSBHost

enum TwitchActivation {
    static func perform(runStart: UInt64) throws -> [ActivationObservation] {
        let service = try M1Discovery.copyInterface(number: 0)
        defer { IOObjectRelease(service) }
        let interface = try IOUSBHostInterface(
            __ioService: service, options: [], queue: nil, interestHandler: nil
        )
        defer { interface.destroy() }
        var observations: [ActivationObservation] = []
        observations.append(observation(
            "opened interface 0 without changing alternate", success: true,
            alternate: interface.interfaceDescriptor.pointee.bAlternateSetting,
            error: nil, runStart: runStart
        ))
        guard interface.interfaceDescriptor.pointee.bAlternateSetting == 0 else {
            throw M1Error.invalidEvidence("interface 0 was not at alternate 0 before activation")
        }

        do {
            try interface.selectAlternateSetting(1)
            observations.append(observation(
                "SET_INTERFACE 0 -> alternate 1", success: true,
                alternate: interface.interfaceDescriptor.pointee.bAlternateSetting,
                error: nil, runStart: runStart
            ))
        } catch {
            observations.append(observation(
                "SET_INTERFACE 0 -> alternate 1", success: false,
                alternate: interface.interfaceDescriptor.pointee.bAlternateSetting,
                error: String(describing: error), runStart: runStart
            ))
            throw error
        }

        do {
            try interface.selectAlternateSetting(0)
            observations.append(observation(
                "SET_INTERFACE 0 -> alternate 0", success: true,
                alternate: interface.interfaceDescriptor.pointee.bAlternateSetting,
                error: nil, runStart: runStart
            ))
        } catch {
            observations.append(observation(
                "SET_INTERFACE 0 -> alternate 0", success: false,
                alternate: interface.interfaceDescriptor.pointee.bAlternateSetting,
                error: String(describing: error), runStart: runStart
            ))
            throw error
        }
        guard interface.interfaceDescriptor.pointee.bAlternateSetting == 0 else {
            throw M1Error.invalidEvidence("interface 0 did not report alternate 0 after restoration")
        }
        return observations
    }

    private static func observation(
        _ operation: String, success: Bool, alternate: UInt8?, error: String?, runStart: UInt64
    ) -> ActivationObservation {
        ActivationObservation(
            operation: operation, wallTimeUTC: M1Discovery.wallTime(),
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds - runStart,
            success: success, observedAlternate: alternate, error: error
        )
    }
}
