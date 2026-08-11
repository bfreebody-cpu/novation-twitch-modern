import Foundation

public struct MIDIExternalMonitorRecord: Codable, Sendable {
    public let kind: String
    public let hostTime: UInt64?
    public let logicalBytes: [UInt8]?
    public let umpWords: [UInt32]?
    public let message: String?
    public let api: String?
    public let sourceEndpoint: UInt32?
    public let protocolID: Int32?
    public let status: Int32?
    public let sourceCount: Int?

    public init(
        kind: String, hostTime: UInt64? = nil, logicalBytes: [UInt8]? = nil,
        umpWords: [UInt32]? = nil, message: String? = nil, api: String? = nil,
        sourceEndpoint: UInt32? = nil, protocolID: Int32? = nil,
        status: Int32? = nil, sourceCount: Int? = nil
    ) {
        self.kind = kind
        self.hostTime = hostTime
        self.logicalBytes = logicalBytes
        self.umpWords = umpWords
        self.message = message
        self.api = api
        self.sourceEndpoint = sourceEndpoint
        self.protocolID = protocolID
        self.status = status
        self.sourceCount = sourceCount
    }
}
