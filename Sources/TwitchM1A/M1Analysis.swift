import Foundation
import IOKit
import TwitchProbeCore

enum M1Analysis {
    static func metrics(result: M1RunResult) -> M1Metrics {
        let assessments = result.midiEvents.map(TwitchBasicInputCatalog.assess)
        let errors = result.rawTransfers.filter { $0.status != kIOReturnSuccess }
        let unexpectedErrors = errors.filter { $0.status != kIOReturnAborted }
        return M1Metrics(
            transferCompletions: result.rawTransfers.count,
            successfulNonemptyTransfers: result.rawTransfers.filter { $0.status == 0 && $0.length > 0 }.count,
            payloadBytes: result.rawTransfers.reduce(0) { $0 + $1.length },
            decodedEvents: result.midiEvents.count,
            parserWarnings: result.midiEvents.filter { $0.kind == "parser-warning" }.count,
            usbErrorsIncludingShutdownAbort: errors.count,
            unexpectedUSBErrors: unexpectedErrors.count,
            maximumObservedTransferSize: result.rawTransfers.map(\.length).max() ?? 0,
            documentedEvents: assessments.filter(\.documented).count,
            undocumentedEvents: assessments.filter { !$0.documented }.count,
            expectationIssues: Set(assessments.compactMap(\.issue)).sorted()
        )
    }
}
