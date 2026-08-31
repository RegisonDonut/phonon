import AppKit
import Foundation

/// Grabs the current screen as a downscaled PNG so the omni model can use
/// on-screen text to disambiguate unclear words. Capturing from inside the
/// .app means macOS attributes the Screen Recording permission to
/// Phonon — keeping every permission under one app.
///
/// Uses the `screencapture` tool (robust across macOS versions) + `sips` to
/// cap the longest side, keeping the model's vision prefill cheap.
enum ScreenCapture {
    /// Returns a temp PNG path, or nil if capture failed / not permitted.
    static func grab(maxPixels: Int = 1568) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("s2t-screen-\(UUID().uuidString).png")

        guard run("/usr/sbin/screencapture", ["-x", "-m", url.path]),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        // Downscale in place (best-effort; ignore failure).
        _ = run("/usr/bin/sips", ["-Z", String(maxPixels), url.path])
        return url
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }
}
