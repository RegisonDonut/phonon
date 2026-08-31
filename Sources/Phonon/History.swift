import Foundation

/// Rolling log of what Phonon transcribed, so a dictation that landed nowhere
/// (no text field focused, wrong app in front, window closed) isn't lost — the
/// menu-bar menu lists the recent ones and copies any of them back.
///
/// JSON file next to the other per-user config:
///   ~/.config/phonon/history.json
enum History {
    struct Entry: Codable {
        let text: String
        let date: Date
    }

    /// Enough to cover a working session; keeps the menu short and the file tiny.
    static let limit = 25

    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/phonon/history.json")
    }

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    /// Prepend a transcript (newest first) and trim to `limit`.
    static func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var entries = load()
        entries.insert(Entry(text: trimmed, date: Date()), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        write(entries)
    }

    static func clear() { write([]) }

    private static func write(_ entries: [Entry]) {
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// One-line menu label: newlines flattened, cut to `max` characters with an
    /// ellipsis. Long dictations would otherwise make the menu unusably wide.
    static func preview(_ text: String, max: Int = 20) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= max { return flat }
        return String(flat.prefix(max)) + "…"
    }
}
