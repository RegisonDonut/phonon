import Foundation

/// User's personal dictionary — names, terms, and spellings the model should
/// honor when they show up in speech (Typeless' "custom vocabulary").
///
/// Plain-text file, one term per line, '#' comments ignored:
///   ~/.config/phonon/vocabulary.txt
///
/// Re-read on each dictation so edits take effect without relaunching.
enum Vocabulary {
    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/phonon/vocabulary.txt")
    }

    static func load() -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
