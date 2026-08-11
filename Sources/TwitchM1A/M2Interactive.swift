import Foundation
import TwitchProbeCore

private struct M2PromptSpec: Sendable {
    let id: String
    let prompt: String
    let expectedControlIDs: [String]
    let validate: @Sendable ([DecodedMIDIEvent]) -> [String]
}

final class M2InteractiveCoordinator: @unchecked Sendable {
    private let recorder: RunRecorder
    private let listener: ControllerListener
    private let bridge: CoreMIDIVirtualSource
    private let lock = NSLock()
    private var completed: [M2VerificationStep] = []

    init(recorder: RunRecorder, listener: ControllerListener, bridge: CoreMIDIVirtualSource) {
        self.recorder = recorder
        self.listener = listener
        self.bridge = bridge
    }

    func start() {
        Thread.detachNewThread { [self] in
            for (index, spec) in Self.specs.enumerated() {
                bridge.waitForMonitorDrain()
                let usbStart = recorder.checkpoint()
                let boundaryStart = bridge.snapshot()
                recorder.note("M2 verification step BEGIN \(spec.id)")
                print("\nM2 step \(index + 1)/\(Self.specs.count): \(spec.prompt)\n")
                print("Press Return when this step is complete.\n")
                fflush(stdout)
                guard readLine() != nil else {
                    recorder.note("standard input ended during M2 verification")
                    listener.requestStop(reason: "interactive input ended")
                    return
                }
                bridge.waitForMonitorDrain()
                let usbEnd = recorder.checkpoint()
                let boundaryEnd = bridge.snapshot()
                let usbEvents = Array(
                    recorder.results().1.dropFirst(usbStart.eventCount)
                        .prefix(usbEnd.eventCount - usbStart.eventCount)
                )
                let published = Array(boundaryEnd.published.dropFirst(boundaryStart.published.count))
                let monitored = Array(boundaryEnd.monitored.dropFirst(boundaryStart.monitored.count))
                let assessments = usbEvents.map(TwitchBasicInputCatalog.assess)
                let controls = Set(assessments.compactMap(\.controlID)).sorted()
                var discrepancies = Set(spec.validate(usbEvents))
                for expected in spec.expectedControlIDs where !controls.contains(expected) {
                    discrepancies.insert("expected USB control not observed: \(expected)")
                }
                let publishable = usbEvents.filter { $0.kind != "parser-warning" }.map(\.bytes)
                let publishedBytes = published.map(\.logicalBytes)
                let monitoredBytes = monitored.map(\.logicalBytes)
                if publishable != publishedBytes {
                    discrepancies.insert(
                        "USB/published mismatch: \(publishable.count) vs \(publishedBytes.count) logical events"
                    )
                }
                if publishedBytes != monitoredBytes {
                    discrepancies.insert(
                        "published/monitored mismatch: \(publishedBytes.count) vs \(monitoredBytes.count) logical events"
                    )
                }
                let step = M2VerificationStep(
                    id: spec.id, prompt: spec.prompt,
                    usbEventCount: usbEvents.count,
                    publishedEventCount: published.count,
                    monitoredEventCount: monitored.count,
                    observedControlIDs: controls, discrepancies: discrepancies.sorted()
                )
                lock.withLock { completed.append(step) }
                recorder.note(
                    "M2 verification step END \(spec.id): USB \(usbEvents.count), published \(published.count), monitored \(monitored.count), flags \(discrepancies.count)"
                )
            }
            listener.requestStop(reason: "interactive M2 verification completed")
        }
    }

    func steps() -> [M2VerificationStep] { lock.withLock { completed } }

    private static let specs: [M2PromptSpec] = [
        M2PromptSpec(
            id: "play-cue",
            prompt: "Press and release left PLAY, then press and release left CUE.",
            expectedControlIDs: ["deck.A.play", "deck.A.cue"], validate: { _ in [] }
        ),
        M2PromptSpec(
            id: "crossfader",
            prompt: "Move the crossfader through a noticeable range.",
            expectedControlIDs: ["crossfader"], validate: { _ in [] }
        ),
        M2PromptSpec(
            id: "rotary-directions",
            prompt: "Turn the left PITCH encoder one click clockwise and one click anticlockwise.",
            expectedControlIDs: ["deck.A.tempo-encoder"], validate: { events in
                let values = events.filter {
                    $0.kind == "control-change" && $0.channel == 8 && $0.data1 == 3
                }.compactMap(\.data2)
                var issues: [String] = []
                if !values.contains(where: { (1...63).contains($0) }) {
                    issues.append("clockwise encoder value 1...63 not observed")
                }
                if !values.contains(where: { (65...127).contains($0) }) {
                    issues.append("anticlockwise encoder value 65...127 not observed")
                }
                return issues
            }
        ),
        M2PromptSpec(
            id: "touchstrip",
            prompt: "Press left SWIPE, then touch, move and release the left touchstrip.",
            expectedControlIDs: ["deck.A.touchstrip-touch", "deck.A.touchstrip-swipe"],
            validate: { _ in [] }
        ),
        M2PromptSpec(
            id: "performance-pad",
            prompt: "Press left HOT CUES, then press and release left performance pad 1.",
            expectedControlIDs: ["deck.A.performance-pad.96"], validate: { _ in [] }
        ),
    ]
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
