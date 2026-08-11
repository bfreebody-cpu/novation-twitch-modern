import Foundation

enum M4Output {
    static func write(_ capture: M4Capture, directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(capture).write(
            to: directory.appendingPathComponent("m4-capture.json"),
            options: .atomic
        )
    }
}
