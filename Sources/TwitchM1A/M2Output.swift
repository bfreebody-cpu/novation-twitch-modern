import Foundation

enum M2Output {
    static func write(_ capture: M2Capture, directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(capture).write(to: directory.appendingPathComponent("m2-capture.json"))
        try writeJSONLines(capture.publishedEvents, to: directory.appendingPathComponent("coremidi-published-events.jsonl"))
        try writeJSONLines(capture.monitoredEvents, to: directory.appendingPathComponent("coremidi-monitored-events.jsonl"))
        try report(capture).write(
            to: directory.appendingPathComponent("m2-report.md"), atomically: true, encoding: .utf8
        )
    }

    static func comparison(
        published: [M2PublishedEvent], monitored: [M2MonitoredEvent], verification: Bool
    ) -> (Bool?, String?) {
        guard verification else { return (nil, nil) }
        let lhs = published.map(\.logicalBytes)
        let rhs = monitored.map(\.logicalBytes)
        guard lhs.count == rhs.count else {
            return (false, "event-count mismatch: published \(lhs.count), monitored \(rhs.count)")
        }
        for index in lhs.indices where lhs[index] != rhs[index] {
            return (false, "event \(index) mismatch: published \(lhs[index]), monitored \(rhs[index])")
        }
        return (true, nil)
    }

    private static func writeJSONLines<T: Encodable>(_ values: [T], to url: URL) throws {
        let encoder = JSONEncoder()
        var data = Data()
        for value in values {
            data.append(try encoder.encode(value))
            data.append(0x0a)
        }
        try data.write(to: url)
    }

    private static func report(_ capture: M2Capture) -> String {
        var text = """
        # Twitch M2 Core MIDI capture

        - Started: \(capture.startedAtUTC)
        - Ended: \(capture.endedAtUTC)
        - Virtual source: \(capture.sourceName)
        - Protocol: \(capture.protocolName)
        - Source created: \(capture.sourceCreationSucceeded)
        - Source enumerated: \(capture.sourceRegistration.foundByEndpoint)
        - USB decoded events: \(capture.usbEventCount)
        - Publishable USB events: \(capture.publishableUSBEventCount)
        - Core MIDI published events: \(capture.publishedEventCount)
        - Core MIDI monitored events: \(capture.monitoredEventCount)
        - Exact published/monitored match: \(capture.exactPublishedToMonitoredMatch.map(String.init) ?? "not monitored")
        - Shutdown: \(capture.shutdownReason)
        - Pipe cancellation: \(capture.abortResult)
        - Interface-0 restoration: \(capture.restorationResult)

        ## Verification steps

        """
        for step in capture.verificationSteps {
            text += "- \(step.id): USB \(step.usbEventCount), published \(step.publishedEventCount), monitored \(step.monitoredEventCount)"
            text += step.discrepancies.isEmpty
                ? "; no discrepancy\n"
                : "; flags: \(step.discrepancies.joined(separator: "; "))\n"
        }
        if !capture.coreMIDIErrors.isEmpty {
            text += "\n## Core MIDI errors\n\n"
            for error in capture.coreMIDIErrors { text += "- \(error)\n" }
        }
        return text
    }
}
