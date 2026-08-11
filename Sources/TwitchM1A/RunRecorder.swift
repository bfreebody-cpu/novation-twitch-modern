import Foundation
import IOKit
import TwitchProbeCore

final class RunRecorder: @unchecked Sendable {
    let directory: URL
    let maximumTransfers: Int
    let maximumPayloadBytes: Int

    private let lock = NSLock()
    private var transfers: [RawUSBTransfer] = []
    private var outputTransfers: [RawUSBOutputTransfer] = []
    private var events: [DecodedMIDIEvent] = []
    private var payloadBytes = 0
    private let transferFile: FileHandle
    private let eventFile: FileHandle
    private let outputTransferFile: FileHandle
    private let textFile: FileHandle
    private let encoder = JSONEncoder()

    init(
        repositoryRoot: URL, maximumTransfers: Int, maximumPayloadBytes: Int,
        captureSuffix: String = "twitch-m1a"
    ) throws {
        self.maximumTransfers = maximumTransfers
        self.maximumPayloadBytes = maximumPayloadBytes
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        directory = repositoryRoot.appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent("\(formatter.string(from: Date()))-\(captureSuffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        transferFile = try Self.createFile(directory.appendingPathComponent("raw-usb-transfers.jsonl"))
        outputTransferFile = try Self.createFile(directory.appendingPathComponent("raw-usb-output-transfers.jsonl"))
        eventFile = try Self.createFile(directory.appendingPathComponent("decoded-midi-events.jsonl"))
        textFile = try Self.createFile(directory.appendingPathComponent("live.log"))
    }

    deinit {
        try? transferFile.close()
        try? eventFile.close()
        try? outputTransferFile.close()
        try? textFile.close()
    }

    func recordTransfer(
        sequence: Int, runStart: UInt64, endpoint: UInt8, status: IOReturn,
        bytesTransferred: Int, buffer: NSMutableData
    ) -> Bool {
        let count = min(max(0, bytesTransferred), buffer.length)
        let payload = count == 0 ? [] : [UInt8](Data(bytes: buffer.bytes, count: count))
        let now = DispatchTime.now().uptimeNanoseconds - runStart
        let description = status == kIOReturnSuccess
            ? "success"
            : String(cString: mach_error_string(status))
        let transfer = RawUSBTransfer(
            sequence: sequence, wallTimeUTC: M1Discovery.wallTime(), monotonicNanoseconds: now,
            endpointAddress: endpoint, status: status,
            statusHex: String(format: "0x%08x", UInt32(bitPattern: status)),
            statusDescription: description, length: count, payload: payload,
            payloadHex: payload.map { String(format: "%02x", $0) }.joined(separator: " ")
        )
        lock.lock()
        defer { lock.unlock() }
        guard transfers.count < maximumTransfers,
              payloadBytes + payload.count <= maximumPayloadBytes else { return false }
        transfers.append(transfer)
        payloadBytes += payload.count
        appendJSON(transfer, to: transferFile)
        let line = String(
            format: "[+%.6fs] USB #%d ep 0x%02x status %@ length %d data %@\n",
            Double(now) / 1_000_000_000, sequence, endpoint, description, count,
            transfer.payloadHex.isEmpty ? "<none>" : transfer.payloadHex
        )
        appendText(line)
        print(line, terminator: "")
        fflush(stdout)
        return true
    }

    func recordEvents(_ decoded: [DecodedMIDIEvent]) {
        lock.lock()
        defer { lock.unlock() }
        for event in decoded {
            events.append(event)
            appendJSON(event, to: eventFile)
            let bytes = event.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            let label = event.controlLabel.map { " [\($0)]" } ?? ""
            let channel = event.channel.map { " ch \($0)" } ?? ""
            let line = String(
                format: "[+%.6fs] MIDI%@ %@: %@%@ bytes %@\n",
                Double(event.monotonicNanoseconds) / 1_000_000_000,
                channel, event.kind, event.semantic, label, bytes
            )
            appendText(line)
            print(line, terminator: "")
        }
        fflush(stdout)
    }

    func recordOutputTransfer(
        sequence: Int, runStart: UInt64, endpoint: UInt8, status: IOReturn,
        requestedPayload: [UInt8], bytesTransferred: Int
    ) {
        let now = DispatchTime.now().uptimeNanoseconds - runStart
        let description = status == kIOReturnSuccess
            ? "success"
            : String(cString: mach_error_string(status))
        let transfer = RawUSBOutputTransfer(
            sequence: sequence, wallTimeUTC: M1Discovery.wallTime(),
            monotonicNanoseconds: now, endpointAddress: endpoint, status: status,
            statusHex: String(format: "0x%08x", UInt32(bitPattern: status)),
            statusDescription: description, requestedLength: requestedPayload.count,
            transferredLength: max(0, bytesTransferred), payload: requestedPayload,
            payloadHex: requestedPayload.map { String(format: "%02x", $0) }.joined(separator: " ")
        )
        lock.lock(); defer { lock.unlock() }
        outputTransfers.append(transfer)
        appendJSON(transfer, to: outputTransferFile)
        let line = String(
            format: "[+%.6fs] USB OUT #%d ep 0x%02x status %@ transferred %d/%d data %@\n",
            Double(now) / 1_000_000_000, sequence, endpoint, description,
            transfer.transferredLength, transfer.requestedLength, transfer.payloadHex
        )
        appendText(line)
        print(line, terminator: "")
        fflush(stdout)
    }

    func note(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "# \(M1Discovery.wallTime()) \(text)\n"
        appendText(line)
        print(line, terminator: "")
        fflush(stdout)
    }

    func results() -> ([RawUSBTransfer], [DecodedMIDIEvent]) {
        lock.lock()
        defer { lock.unlock() }
        return (transfers, events)
    }

    func outputResults() -> [RawUSBOutputTransfer] {
        lock.lock(); defer { lock.unlock() }
        return outputTransfers
    }

    func checkpoint() -> M1RecorderCheckpoint {
        lock.lock()
        defer { lock.unlock() }
        return M1RecorderCheckpoint(transferCount: transfers.count, eventCount: events.count)
    }

    private func appendJSON<T: Encodable>(_ value: T, to file: FileHandle) {
        guard let data = try? encoder.encode(value) else { return }
        file.write(data)
        file.write(Data([0x0a]))
    }

    private func appendText(_ text: String) { textFile.write(Data(text.utf8)) }

    private static func createFile(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try FileHandle(forWritingTo: url)
    }
}
