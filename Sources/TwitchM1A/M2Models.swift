import Foundation
import TwitchProbeCore

struct M2PublishedEvent: Codable {
    let index: Int
    let monotonicNanoseconds: UInt64
    let coreMIDIHostTime: UInt64
    let transferSequence: Int
    let logicalBytes: [UInt8]
    let umpWords: [UInt32]
    let status: Int32
}

struct M2MonitoredEvent: Codable {
    let index: Int
    let coreMIDIHostTime: UInt64
    let logicalBytes: [UInt8]
    let umpWords: [UInt32]
}

struct M2SourceRegistration: Codable {
    let sourceName: String
    let sourceEndpoint: UInt32
    let enumeratedSourceCount: Int
    let foundByEndpoint: Bool
    let enumeratedName: String?
    let protocolID: Int32?
}

struct M2BoundarySnapshot {
    let published: [M2PublishedEvent]
    let monitored: [M2MonitoredEvent]
    let errors: [String]
}

struct M2VerificationStep: Codable {
    let id: String
    let prompt: String
    let usbEventCount: Int
    let publishedEventCount: Int
    let monitoredEventCount: Int
    let observedControlIDs: [String]
    let discrepancies: [String]
}

struct M2Capture: Codable {
    let schemaVersion: Int
    let milestone: String
    let startedAtUTC: String
    let endedAtUTC: String
    let sourceCreationSucceeded: Bool
    let sourceRegistration: M2SourceRegistration
    let sourceName: String
    let protocolName: String
    let coreMIDIAPI: [String]
    let verificationEnabled: Bool
    let verificationSteps: [M2VerificationStep]
    let publishedEvents: [M2PublishedEvent]
    let monitoredEvents: [M2MonitoredEvent]
    let coreMIDIErrors: [String]
    let usbEventCount: Int
    let publishableUSBEventCount: Int
    let publishedEventCount: Int
    let monitoredEventCount: Int
    let exactPublishedToMonitoredMatch: Bool?
    let firstPublishedToMonitoredMismatch: String?
    let shutdownReason: String
    let abortResult: String
    let restorationResult: String
    let parserIncompleteStateAtShutdown: String?
    let stateBefore: M1StateSnapshot
    let stateAfter: M1StateSnapshot?
    let activation: [ActivationObservation]
    let safetyStatement: [String]
}

