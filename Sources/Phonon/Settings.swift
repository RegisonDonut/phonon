import Foundation

/// Lightweight user settings read from ~/.config/phonon/.
enum Settings {
    private static var dir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/phonon")
    }

    /// Screenshot-assisted disambiguation. Default OFF for speed — it adds a
    /// second model pass (~+1-2s) to annotate against on-screen words. Enable
    /// when you need it (no rebuild, read fresh each dictation):
    ///   echo on  > ~/.config/phonon/screenshot
    ///   echo off > ~/.config/phonon/screenshot
    static var screenshotEnabled: Bool {
        let url = dir.appendingPathComponent("screenshot")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v == "1" || v == "on" || v == "true" || v == "yes"
    }
}
