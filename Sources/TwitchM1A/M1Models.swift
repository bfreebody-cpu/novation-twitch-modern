import Foundation
import TwitchProbeCore

struct M1RegistryEntry: Codable {
    let registryEntryID: UInt64
    let name: String
    let ioClass: String
    let busyState: UInt32?
    let properties: [String: String]
}

struct M1StateSnapshot: Codable {
    let phase: String
    let wallTimeUTC: String
    let monotonicNanoseconds: UInt64
    let device: M1RegistryEntry
    let interfaces: [M1RegistryEntry]
}

struct ActivationObservation: Codable {
    let operation: String
    let wallTimeUTC: String
    let monotonicNanoseconds: UInt64
    let success: Bool
    let observedAlternate: UInt8?
    let error: String?
}

struct RawUSBTransfer: Codable, Sendable {
    let sequence: Int
    let wallTimeUTC: String
    let monotonicNanoseconds: UInt64
    let endpointAddress: UInt8
    let status: Int32
    let statusHex: String
    let statusDescription: String
    let length: Int
    let payload: [UInt8]
    let payloadHex: String
}

struct RawUSBOutputTransfer: Codable, Sendable {
    let sequence: Int
    let wallTimeUTC: String
    let monotonicNanoseconds: UInt64
    let endpointAddress: UInt8
    let status: Int32
    let statusHex: String
    let statusDescription: String
    let requestedLength: Int
    let transferredLength: Int
    let payload: [UInt8]
    let payloadHex: String
}

struct M1Limits: Codable {
    let endpointMaximumPacketSize: Int
    let concurrentReads: Int
    let maximumTransfers: Int
    let maximumPayloadBytesLogged: Int
    let maximumSysExBytes: Int
    let durationSeconds: Int
}

struct M1TestStep: Codable {
    let id: String
    let prompt: String
    let startedMonotonicNanoseconds: UInt64
    let endedMonotonicNanoseconds: UInt64
    let firstTransferSequence: Int?
    let lastTransferSequence: Int?
    let firstEventIndex: Int?
    let lastEventIndex: Int?
    let expectedCategories: [String]
    let expectedControlIDs: [String]
    let observedCategories: [String]
    let observedControlIDs: [String]
    let discrepancies: [String]
}

struct M1Metrics: Codable {
    let transferCompletions: Int
    let successfulNonemptyTransfers: Int
    let payloadBytes: Int
    let decodedEvents: Int
    let parserWarnings: Int
    let usbErrorsIncludingShutdownAbort: Int
    let unexpectedUSBErrors: Int
    let maximumObservedTransferSize: Int
    let documentedEvents: Int
    let undocumentedEvents: Int
    let expectationIssues: [String]
}

struct M1ReconnectObservation: Codable {
    let disconnectHandled: Bool
    let disconnectReason: String
    let reconnectRequestedAtUTC: String?
    let reconnectedDeviceDiscovered: Bool
    let reconnectedAtUTC: String?
    let waitSeconds: Int
    let policy: String
    let error: String?
}

struct M1Capture: Codable {
    let schemaVersion: Int
    let milestone: String
    let startedAtUTC: String
    let endedAtUTC: String
    let hostOperatingSystem: String
    let hostArchitecture: String
    let deviceDescriptor: DeviceDescriptor
    let configurations: [ConfigurationDescriptor]
    let limits: M1Limits
    let stateBefore: M1StateSnapshot
    let activation: [ActivationObservation]
    let stateAfterActivation: M1StateSnapshot?
    let rawTransfers: [RawUSBTransfer]
    let midiEvents: [DecodedMIDIEvent]
    let shutdownReason: String
    let abortResult: String
    let restorationResult: String
    let parserIncompleteStateAtShutdown: String?
    let stateAfter: M1StateSnapshot?
    let testSteps: [M1TestStep]
    let metrics: M1Metrics
    let reconnectObservation: M1ReconnectObservation?
    let operatorNotes: [String]
    let safetyStatement: [String]
}

struct M1Baseline {
    let rawDevice: Data
    let device: DeviceDescriptor
    let rawConfigurations: [Data]
    let configurations: [ConfigurationDescriptor]
    let state: M1StateSnapshot
}

struct M1RunResult {
    let rawTransfers: [RawUSBTransfer]
    let midiEvents: [DecodedMIDIEvent]
    let shutdownReason: String
    let abortResult: String
    let restorationResult: String
    let parserIncompleteState: String?
}

struct M1RecorderCheckpoint {
    let transferCount: Int
    let eventCount: Int
}
