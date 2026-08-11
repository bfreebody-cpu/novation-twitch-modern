import Foundation

struct M4OutputQueueSnapshot: Codable {
    let queuedPackets: Int
    let transferInFlight: Bool
    let rejectedPackets: Int
}

struct M4Capture: Codable {
    let schemaVersion: Int
    let milestone: String
    let mode: String
    let startedAtUTC: String
    let endedAtUTC: String
    let sourceRegistration: M2SourceRegistration?
    let destinationRegistration: M4DestinationRegistration?
    let coreMIDIOutputEvents: [M4CoreMIDIOutputEvent]
    let coreMIDIErrors: [String]
    let usbInputTransferCount: Int
    let decodedInputEventCount: Int
    let usbOutputTransfers: [RawUSBOutputTransfer]
    let outputQueueAtShutdown: M4OutputQueueSnapshot?
    let shutdownReason: String
    let inputAbortResult: String
    let restorationResult: String
    let stateBefore: M1StateSnapshot
    let stateAfter: M1StateSnapshot?
    let activation: [ActivationObservation]
    let operatorNotes: [String]
    let safetyStatement: [String]
}
