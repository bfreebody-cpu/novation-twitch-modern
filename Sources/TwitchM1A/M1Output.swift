import CryptoKit
import Foundation
import TwitchProbeCore

enum M1Output {
    static func write(
        capture: M1Capture, baseline: M1Baseline, directory: URL
    ) throws {
        try writeRawEvidence(baseline: baseline, directory: directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(capture).write(to: directory.appendingPathComponent("capture.json"))
        try report(capture).write(
            to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8
        )
    }

    static func writeRawEvidence(baseline: M1Baseline, directory: URL) throws {
        try writeRaw(baseline.rawDevice, name: "device-descriptor", directory: directory)
        for (index, data) in baseline.rawConfigurations.enumerated() {
            try writeRaw(data, name: "configuration-\(index)-descriptor-tree", directory: directory)
        }
    }

    private static func writeRaw(_ data: Data, name: String, directory: URL) throws {
        try data.write(to: directory.appendingPathComponent("\(name).bin"))
        let hex = stride(from: 0, to: data.count, by: 16).map { offset in
            let end = min(offset + 16, data.count)
            return String(format: "%04x  ", offset) + data[offset..<end]
                .map { String(format: "%02x", $0) }.joined(separator: " ")
        }.joined(separator: "\n") + "\n"
        try hex.write(
            to: directory.appendingPathComponent("\(name).hex.txt"), atomically: true, encoding: .utf8
        )
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try "\(digest)  \(name).bin\n".write(
            to: directory.appendingPathComponent("\(name).sha256.txt"), atomically: true, encoding: .utf8
        )
    }

    private static func report(_ capture: M1Capture) -> String {
        let successfulTransfers = capture.rawTransfers.filter { $0.status == 0 && $0.length > 0 }
        var text = """
        # Twitch \(capture.milestone) activation and controller-input capture

        - Started: \(capture.startedAtUTC)
        - Ended: \(capture.endedAtUTC)
        - Shutdown: \(capture.shutdownReason)
        - Pipe cancellation: \(capture.abortResult)
        - Interface-0 restoration: \(capture.restorationResult)
        - USB completions logged: \(capture.rawTransfers.count)
        - Successful nonempty controller transfers: \(successfulTransfers.count)
        - Decoded MIDI events: \(capture.midiEvents.count)
        - Payload bytes: \(capture.metrics.payloadBytes)
        - Maximum observed transfer size: \(capture.metrics.maximumObservedTransferSize)
        - Parser warnings: \(capture.metrics.parserWarnings)
        - Unexpected USB errors: \(capture.metrics.unexpectedUSBErrors)
        - Documented / undocumented events: \(capture.metrics.documentedEvents) / \(capture.metrics.undocumentedEvents)

        """
        if !capture.operatorNotes.isEmpty {
            text += "\n## Operator observations\n\n"
            for note in capture.operatorNotes { text += "- \(note)\n" }
        }
        text += "\n## Activation\n\n"
        for step in capture.activation {
            text += "- \(step.operation): \(step.success ? "succeeded" : "failed")"
            if let alternate = step.observedAlternate { text += "; observed alternate \(alternate)" }
            if let error = step.error { text += "; error \(error)" }
            text += "\n"
        }
        text += "\n## Raw controller transfers\n\n"
        if successfulTransfers.isEmpty { text += "No nonempty successful controller payload was observed.\n" }
        let lengthCounts = Dictionary(grouping: successfulTransfers, by: \.length).mapValues(\.count)
        for length in lengthCounts.keys.sorted() {
            text += "- \(length)-byte transfers: \(lengthCounts[length]!)\n"
        }
        if capture.milestone == "M1a" {
            for transfer in successfulTransfers {
                text += String(
                    format: "- +%.6fs, transfer %d, status %@, %d bytes: `%@`\n",
                    Double(transfer.monotonicNanoseconds) / 1_000_000_000,
                    transfer.sequence, transfer.statusDescription, transfer.length, transfer.payloadHex
                )
            }
        }
        text += "\n## Decoded MIDI events\n\n"
        if capture.midiEvents.isEmpty { text += "No complete MIDI event was decoded.\n" }
        if capture.milestone == "M1a" {
            for event in capture.midiEvents {
                let bytes = event.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                let label = event.controlLabel.map { " — \($0)" } ?? ""
                text += String(
                    format: "- +%.6fs, %@%@, bytes `%@`\n",
                    Double(event.monotonicNanoseconds) / 1_000_000_000,
                    event.semantic, label, bytes
                )
            }
        } else {
            let controls = Set(capture.midiEvents.compactMap(\.controlLabel)).sorted()
            text += "Observed documented control labels:\n"
            for control in controls { text += "- \(control)\n" }
        }
        if !capture.testSteps.isEmpty {
            text += "\n## Interactive test steps\n\n"
            for step in capture.testSteps {
                text += "### \(step.id)\n\n"
                text += "- Observed categories: \(step.observedCategories.joined(separator: ", "))\n"
                text += "- Observed controls: \(step.observedControlIDs.joined(separator: ", "))\n"
                if step.discrepancies.isEmpty {
                    text += "- Automatic comparison: no discrepancy flagged\n"
                } else {
                    text += "- Automatic comparison flags: \(step.discrepancies.joined(separator: "; "))\n"
                }
            }
        }
        if !capture.metrics.expectationIssues.isEmpty {
            text += "\n## Catalog comparison issues\n\n"
            for issue in capture.metrics.expectationIssues { text += "- \(issue)\n" }
        }
        if let reconnect = capture.reconnectObservation {
            text += "\n## Disconnect/reconnect\n\n"
            text += "- Disconnect handled: \(reconnect.disconnectHandled)\n"
            text += "- Reconnected device discovered: \(reconnect.reconnectedDeviceDiscovered)\n"
            text += "- Policy: \(reconnect.policy)\n"
            if let error = reconnect.error { text += "- Error: \(error)\n" }
        }
        if let state = capture.parserIncompleteStateAtShutdown {
            text += "\nParser state at shutdown: \(state).\n"
        }
        text += "\nSee `capture.json`, `raw-usb-transfers.jsonl`, `decoded-midi-events.jsonl`, and `live.log` for machine-readable and chronological evidence.\n"
        return text
    }
}
