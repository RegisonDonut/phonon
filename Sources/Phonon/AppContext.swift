import AppKit

/// The frontmost application's bundle id, used so the omni model can adapt
/// tone/style to where you're typing (email vs chat vs code) — Typeless'
/// "context-aware adaptation".
enum AppContext {
    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
