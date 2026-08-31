import Foundation

/// Durable rolling storage for the latest recordings. Audio is saved before
/// transcription starts, so a server/audio failure never destroys the source
/// needed for a manual retry.
enum RecordingStore {
    struct Entry: Codable, Identifiable {
        enum Kind: String, Codable { case dictate, edit }

        let id: UUID
        let date: Date
        let duration: Double
        let fileName: String
        let kind: Kind
        let selectedText: String?
        let appBundleID: String?
        var screenKeywords: [String]
        var transcript: String?
    }

    static let limit = 10

    static var directoryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/phonon/recordings", isDirectory: true)
    }

    private static var indexURL: URL {
        directoryURL.appendingPathComponent("index.json")
    }

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    static func entry(id: UUID) -> Entry? {
        load().first { $0.id == id }
    }

    static func audioURL(for entry: Entry) -> URL {
        directoryURL.appendingPathComponent(entry.fileName)
    }

    static func add(samples: [Float], kind: Entry.Kind, selectedText: String?,
                    appBundleID: String?) throws -> Entry {
        try FileManager.default.createDirectory(at: directoryURL,
                                                withIntermediateDirectories: true)
        let id = UUID()
        let fileName = "\(id.uuidString).wav"
        let entry = Entry(id: id, date: Date(),
                          duration: Double(samples.count) / 16_000,
                          fileName: fileName, kind: kind,
                          selectedText: selectedText, appBundleID: appBundleID,
                          screenKeywords: [], transcript: nil)
        _ = try AudioFile.writeWAV(samples: samples, to: audioURL(for: entry))

        var entries = load()
        entries.insert(entry, at: 0)
        if entries.count > limit {
            for old in entries.dropFirst(limit) {
                try? FileManager.default.removeItem(at: audioURL(for: old))
            }
            entries = Array(entries.prefix(limit))
        }
        try write(entries)
        return entry
    }

    static func setScreenKeywords(_ keywords: [String], for id: UUID) {
        update(id: id) { $0.screenKeywords = keywords }
    }

    static func setTranscript(_ text: String, for id: UUID) {
        update(id: id) { $0.transcript = text }
    }

    private static func update(id: UUID, change: (inout Entry) -> Void) {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
        try? write(entries)
    }

    private static func write(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: directoryURL,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: indexURL, options: .atomic)
    }
}
