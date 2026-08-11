import Foundation

public struct TwitchInputAssessment: Codable, Equatable, Sendable {
    public let documented: Bool
    public let controlID: String?
    public let category: String?
    public let label: String?
    public let issue: String?

    public init(documented: Bool, controlID: String?, category: String?, label: String?, issue: String?) {
        self.documented = documented
        self.controlID = controlID
        self.category = category
        self.label = label
        self.issue = issue
    }
}

/// Basic-mode MIDI identities from the supplied Twitch Programmer's Reference,
/// labeled with the original physical panel names from the supplied User Guide.
/// The Programmer's Reference illustrations use a Traktor overlay whose printed
/// names differ at notes 10, 13, and 16 through 19. This catalog classifies only
/// device-to-host messages; it contains no output commands.
public enum TwitchBasicInputCatalog {
    public static func assess(_ event: DecodedMIDIEvent) -> TwitchInputAssessment {
        guard event.kind == "note-on" || event.kind == "note-off" || event.kind == "control-change" else {
            return TwitchInputAssessment(
                documented: false, controlID: nil, category: nil, label: nil,
                issue: "unclassified non-note/non-CC input: \(event.semantic)"
            )
        }
        guard let channel = event.channel, let number = event.data1, let value = event.data2 else {
            return TwitchInputAssessment(
                documented: false, controlID: nil, category: nil, label: nil,
                issue: "channel input lacks channel/controller/value fields"
            )
        }
        if event.kind == "control-change" {
            return assessControlChange(channel: channel, number: number, value: value)
        }
        return assessNote(channel: channel, number: number, velocity: value)
    }

    public static func label(command: UInt8, channel: Int, number: UInt8) -> String? {
        let placeholder = DecodedMIDIEvent(
            monotonicNanoseconds: 0, transferSequence: 0,
            bytes: [command | UInt8(channel - 1), number, command == 0xb0 ? 1 : 127],
            kind: command == 0xb0 ? "control-change" : "note-on", channel: channel,
            data1: number, data2: command == 0xb0 ? 1 : 127, semantic: "", controlLabel: nil
        )
        return assess(placeholder).label
    }

    private static func assessNote(channel: Int, number: UInt8, velocity: UInt8) -> TwitchInputAssessment {
        let deck = deckName(channel)
        let match: (String, String, String)?
        switch (channel, number) {
        case (8, 9): match = ("direct-monitor", "other", "rear direct-monitor switch")
        case (8...9, 0): match = ("deck-select.\(deck!)", "deck-selection", "\(deck!) SHIFT / alternate-page toggle")
        case (8...11, 3): match = ("deck.\(deck!).tempo-encoder-press", "rotary-encoders", "\(deck!) tempo encoder press")
        case (8...9, 6): match = ("deck.\(deck!).fx-select-encoder-press", "rotary-encoders", "\(deck!) FX-select encoder press")
        case (8...11, 10): match = ("deck.\(deck!).headphone", "transport-buttons", "\(deck!) headphone/PFL")
        case (8...11, 13): match = ("deck.\(deck!).fader-fx-on", "transport-buttons", "\(deck!) FADER FX ON/OFF")
        case (8...11, 16): match = ("deck.\(deck!).beat-grid-set", "transport-buttons", "\(deck!) BEAT GRID SET/CLR")
        case (8...11, 17): match = ("deck.\(deck!).beat-grid-adjust", "transport-buttons", "\(deck!) BEAT GRID ADJUST/SLIP")
        case (8...11, 18): match = ("deck.\(deck!).keylock", "transport-buttons", "\(deck!) KEYLOCK")
        case (8...11, 19): match = ("deck.\(deck!).sync", "transport-buttons", "\(deck!) SYNC/AUTO")
        case (8...11, 22): match = ("deck.\(deck!).cue", "transport-buttons", "\(deck!) CUE")
        case (8...11, 23): match = ("deck.\(deck!).play", "transport-buttons", "\(deck!) PLAY/Pause")
        case (8...11, 56...59):
            match = ("deck.\(deck!).performance-mode.\(number)", "performance", "\(deck!) performance-mode button \(number)")
        case (8...11, 71): match = ("deck.\(deck!).touchstrip-touch", "touchstrips", "\(deck!) touchstrip touch/position")
        case (8, 80): match = ("browse.browser-area", "browse-navigation", "BROWSER/AREA")
        case (8, 81): match = ("browse.four-deck-view", "browse-navigation", "4 DECK/VIEW")
        case (8, 82): match = ("browse.load-left", "browse-navigation", "LOAD A/C")
        case (8, 83): match = ("browse.load-right", "browse-navigation", "LOAD B/D")
        case (8, 84): match = ("browse.close", "browse-navigation", "CLOSE/BACK")
        case (8, 85): match = ("browse.encoder-press", "browse-navigation", "browse encoder press")
        case (8, 86): match = ("browse.open", "browse-navigation", "OPEN/FWD")
        case (8...11, 96...127):
            match = ("deck.\(deck!).performance-pad.\(number)", "performance", "\(deck!) paged performance pad note \(number)")
        case (12, 28...31): match = ("fx.params.\(number - 27)", "fx-section", "FX PARAMS \(number - 27)")
        case (12, 32...35): match = ("fx.on.\(number - 31)", "fx-section", "FX ON \(number - 31)")
        default: match = nil
        }
        guard let match else { return undocumented(channel: channel, number: number, kind: "note") }
        let velocityIssue: String?
        if match.1 == "touchstrips" {
            velocityIssue = nil // 1...127 is position-on; 0 is release.
        } else if match.0 == "direct-monitor" {
            velocityIssue = velocity == 0 || velocity == 127 ? nil : "direct-monitor velocity must be 0 or 127"
        } else {
            velocityIssue = velocity == 0 || velocity == 127 ? nil : "button velocity must be 0 or 127"
        }
        return TwitchInputAssessment(
            documented: true, controlID: match.0, category: match.1, label: match.2, issue: velocityIssue
        )
    }

    private static func assessControlChange(
        channel: Int, number: UInt8, value: UInt8
    ) -> TwitchInputAssessment {
        let deck = deckName(channel)
        let match: (String, String, String, Bool)?
        switch (channel, number) {
        case (8, 8): match = ("crossfader", "crossfader", "crossfader", false)
        case (8...11, 3): match = ("deck.\(deck!).tempo-encoder", "rotary-encoders", "\(deck!) tempo encoder", true)
        case (8...9, 6): match = ("deck.\(deck!).fx-select-encoder", "rotary-encoders", "\(deck!) FX-select encoder", true)
        case (8...11, 7): match = ("deck.\(deck!).channel-fader", "channel-faders", "\(deck!) channel fader", false)
        case (8...11, 9): match = ("deck.\(deck!).gain", "gain-controls", "\(deck!) trim/gain", false)
        case (8...11, 70): match = ("deck.\(deck!).eq-low", "eq-controls", "\(deck!) low EQ", false)
        case (8...11, 71): match = ("deck.\(deck!).eq-mid", "eq-controls", "\(deck!) mid EQ", false)
        case (8...11, 72): match = ("deck.\(deck!).eq-high", "eq-controls", "\(deck!) high EQ", false)
        case (8...11, 52): match = ("deck.\(deck!).touchstrip-drop", "touchstrips", "\(deck!) touchstrip DROP absolute position", false)
        case (8...11, 53): match = ("deck.\(deck!).touchstrip-swipe", "touchstrips", "\(deck!) touchstrip SWIPE incremental movement", true)
        case (8, 85): match = ("browse.encoder", "browse-navigation", "browse encoder", true)
        case (12, 0...19):
            let position = Int(number) % 4
            let names = ["left potentiometer", "left encoder", "right encoder", "right potentiometer"]
            let isEncoder = position == 1 || position == 2
            match = ("fx.page-dependent.\(number)", "fx-section", "FX page-dependent \(names[position]) (CC \(number))", isEncoder)
        default: match = nil
        }
        guard let match else { return undocumented(channel: channel, number: number, kind: "CC") }
        let issue = match.3 && value == 0 ? "incremental encoder/touchstrip value 0 is not a documented movement" : nil
        return TwitchInputAssessment(
            documented: true, controlID: match.0, category: match.1, label: match.2, issue: issue
        )
    }

    private static func deckName(_ channel: Int) -> String? {
        [8: "A", 9: "B", 10: "C", 11: "D"][channel]
    }

    private static func undocumented(channel: Int, number: UInt8, kind: String) -> TwitchInputAssessment {
        TwitchInputAssessment(
            documented: false, controlID: nil, category: nil, label: nil,
            issue: "undocumented basic-mode \(kind) input on MIDI channel \(channel), number \(number)"
        )
    }
}
