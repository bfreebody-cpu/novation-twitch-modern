import Foundation
import TwitchProbeCore

private struct M1PromptSpec {
    let id: String
    let prompt: String
    let expectedCategories: [String]
    let expectedControlIDs: [String]
}

final class M1InteractiveCoordinator: @unchecked Sendable {
    private let recorder: RunRecorder
    private let listener: ControllerListener
    private let runStart: UInt64
    private let lock = NSLock()
    private var completedSteps: [M1TestStep] = []

    init(recorder: RunRecorder, listener: ControllerListener, runStart: UInt64) {
        self.recorder = recorder
        self.listener = listener
        self.runStart = runStart
    }

    func start(atOneBasedStep requestedStep: Int = 1) {
        Thread.detachNewThread { [self] in
            let startIndex = min(max(0, requestedStep - 1), Self.specs.count - 1)
            for (index, spec) in Self.specs.enumerated().dropFirst(startIndex) {
                let start = recorder.checkpoint()
                let startTime = DispatchTime.now().uptimeNanoseconds - runStart
                recorder.note("M1b step BEGIN \(spec.id)")
                print("\nM1b step \(index + 1)/\(Self.specs.count): \(spec.prompt)\n")
                print("Press Return when this step is complete. Do not combine BACK + FWD + browse-press.\n")
                fflush(stdout)
                guard readLine() != nil else {
                    recorder.note("standard input ended during interactive characterization")
                    listener.requestStop(reason: "interactive input ended")
                    return
                }
                let endTime = DispatchTime.now().uptimeNanoseconds - runStart
                let end = recorder.checkpoint()
                let all = recorder.results()
                let eventSlice = Array(all.1.dropFirst(start.eventCount).prefix(end.eventCount - start.eventCount))
                let assessments = eventSlice.map(TwitchBasicInputCatalog.assess)
                let categories = Set(assessments.compactMap(\.category)).sorted()
                let controlIDs = Set(assessments.compactMap(\.controlID)).sorted()
                var discrepancies = Set(assessments.compactMap(\.issue))
                for category in spec.expectedCategories where !categories.contains(category) {
                    discrepancies.insert("expected category not observed in step: \(category)")
                }
                for controlID in spec.expectedControlIDs where !controlIDs.contains(controlID) {
                    discrepancies.insert("expected control not observed in step: \(controlID)")
                }
                let step = M1TestStep(
                    id: spec.id, prompt: spec.prompt,
                    startedMonotonicNanoseconds: startTime, endedMonotonicNanoseconds: endTime,
                    firstTransferSequence: start.transferCount < end.transferCount ? start.transferCount + 1 : nil,
                    lastTransferSequence: start.transferCount < end.transferCount ? end.transferCount : nil,
                    firstEventIndex: start.eventCount < end.eventCount ? start.eventCount : nil,
                    lastEventIndex: start.eventCount < end.eventCount ? end.eventCount - 1 : nil,
                    expectedCategories: spec.expectedCategories,
                    expectedControlIDs: spec.expectedControlIDs,
                    observedCategories: categories, observedControlIDs: controlIDs,
                    discrepancies: discrepancies.sorted()
                )
                lock.withLock { completedSteps.append(step) }
                recorder.note(
                    "M1b step END \(spec.id): \(eventSlice.count) events, \(discrepancies.count) discrepancy flags"
                )
            }
            listener.requestStop(reason: "interactive M1b characterization completed")
        }
    }

    func steps() -> [M1TestStep] { lock.withLock { completedSteps } }

    private static let specs: [M1PromptSpec] = [
        M1PromptSpec(
            id: "transport-buttons-ab",
            prompt: "With A/B selected, press/release each side's physical SET/CLR, ADJUST/SLIP, KEYLOCK, SYNC/AUTO, CUE, PLAY, headphone A/B, and FADER FX ON/OFF buttons.",
            expectedCategories: ["transport-buttons"],
            expectedControlIDs: [8, 9].flatMap { channel in
                let deck = channel == 8 ? "A" : "B"
                return ["sync", "shift", "back", "forward", "cue", "play", "filter-on", "headphone"].map { "deck.\(deck).\($0)" }
            }
        ),
        M1PromptSpec(
            id: "mixer-continuous-ab",
            prompt: "Move both channel faders, both TRIM/gain controls, and all six LOW/MID/HIGH EQ controls through representative ranges (cross any pickup point). Move the crossfader through a representative range too.",
            expectedCategories: ["channel-faders", "gain-controls", "eq-controls", "crossfader"],
            expectedControlIDs: ["crossfader"] + ["A", "B"].flatMap { deck in
                ["channel-fader", "gain", "eq-low", "eq-mid", "eq-high"].map { "deck.\(deck).\($0)" }
            }
        ),
        M1PromptSpec(
            id: "deck-encoders-ab",
            prompt: "For both decks, turn the large PITCH encoder clockwise and anticlockwise and press/release it. Do the same for each FADER FX SELECT/ACTIVATE encoder.",
            expectedCategories: ["rotary-encoders"],
            expectedControlIDs: ["A", "B"].flatMap { deck in
                ["tempo-encoder", "tempo-encoder-press", "fx-select-encoder", "fx-select-encoder-press"].map { "deck.\(deck).\($0)" }
            }
        ),
        M1PromptSpec(
            id: "deck-selection-cd",
            prompt: "Use each deck's separate SHIFT button to select the hidden C/D basic-mode page. On each selected page, press/release PLAY and move its channel fader. Press SHIFT again so both SHIFT lights are off and A/B is restored.",
            expectedCategories: ["deck-selection", "transport-buttons", "channel-faders"],
            expectedControlIDs: ["deck-select.A", "deck-select.B", "deck.C.play", "deck.C.channel-fader", "deck.D.play", "deck.D.channel-fader"]
        ),
        M1PromptSpec(
            id: "browse-navigation",
            prompt: "In the physical BROWSE section, press/release AREA, VIEW, LOAD A, LOAD B, BACK and FWD. Turn SCROLL both directions and press/release it. Never hold BACK and FWD while pressing SCROLL.",
            expectedCategories: ["browse-navigation"],
            expectedControlIDs: ["browse.browser-area", "browse.four-deck-view", "browse.load-left", "browse.load-right", "browse.close", "browse.open", "browse.encoder", "browse.encoder-press"]
        ),
        M1PromptSpec(
            id: "performance-sections",
            prompt: "On each side, select physical HOT CUES, SLICER, AUTOLOOP and LOOP ROLL in turn; press/release pad 1 after each selection and also pad 8 on at least one page.",
            expectedCategories: ["performance"], expectedControlIDs: []
        ),
        M1PromptSpec(
            id: "fx-section",
            prompt: "Press/release physical MASTER FX AUX, DECK A, DECK B, both FX SELECT arrows and ON/OFF, plus MIC/AUX headphone and ON/OFF. Move DEPTH and LEVEL; turn MOD/X and BEATS both directions and press them if they click. Repeat brief rotary movement after two page selections.",
            expectedCategories: ["fx-section"],
            expectedControlIDs: (1...4).flatMap { ["fx.params.\($0)", "fx.on.\($0)"] }
        ),
        M1PromptSpec(
            id: "touchstrips",
            prompt: "With A/B selected, touch, move and release both touchstrips in SWIPE mode. Then select DROP on each side and touch/move/release each strip once. SWIPE/DROP themselves are expected to emit no MIDI in basic mode.",
            expectedCategories: ["touchstrips"],
            expectedControlIDs: ["deck.A.touchstrip-touch", "deck.A.touchstrip-swipe", "deck.A.touchstrip-drop", "deck.B.touchstrip-touch", "deck.B.touchstrip-swipe", "deck.B.touchstrip-drop"]
        ),
        M1PromptSpec(
            id: "direct-monitor",
            prompt: "Move the rear DIRECT MONITORING switch to the opposite position and back. Do not move the BOOTH OUTPUT switch; it is audio-only.",
            expectedCategories: ["other"], expectedControlIDs: ["direct-monitor"]
        ),
        M1PromptSpec(
            id: "simultaneous-fader-eq-transport",
            prompt: "Move one channel fader while turning an EQ control. Then hold PLAY or CUE while moving a different continuous control.",
            expectedCategories: ["channel-faders", "eq-controls", "transport-buttons"], expectedControlIDs: []
        ),
        M1PromptSpec(
            id: "rapid-encoder-touchstrip-combination",
            prompt: "Turn an encoder rapidly in both directions. Then move a touchstrip while changing the crossfader or a channel fader. Release every control before finishing.",
            expectedCategories: ["rotary-encoders", "touchstrips"], expectedControlIDs: []
        ),
    ]
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
