import AppKit
import AVFoundation
import ApplicationServices
import IOKit.hid

/// Proactively triggers the native permission prompts (the same kind the
/// microphone shows) so the user doesn't have to hunt through System Settings.
enum Permissions {
    /// Fire all the requests at launch. Each shows a system prompt with an
    /// "Open System Settings" button when not yet granted.
    static func requestAtLaunch() {
        // Microphone
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // Input Monitoring (keystroke listening for the global hotkey)
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        // Accessibility (to synthesize ⌘C / ⌘V) — shows the standard prompt
        // with an "Open System Settings" button.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Request Screen Recording (only needed when screenshot mode is on).
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    // Direct links to the relevant System Settings panes (fallback).
    static func openInputMonitoring() { openPane("Privacy_ListenEvent") }
    static func openAccessibility() { openPane("Privacy_Accessibility") }

    /// Snapshot of every grant the app needs, written to /tmp/phonon-selfcheck.json
    /// at launch. `CGEvent.tapCreate` succeeds even without Input Monitoring —
    /// the tap just never receives anything — so "hotkey silently dead" can only
    /// be diagnosed by asking TCC directly, which is what this does.
    static func snapshot() -> [String: Any] {
        [
            "path": Bundle.main.bundlePath,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "inputMonitoring": inputMonitoringGranted,
            "accessibility": accessibilityGranted,
            "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            "screenRecording": screenRecordingGranted,
            "when": ISO8601DateFormatter().string(from: Date()),
        ]
    }

    static func writeSelfCheck() {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot(),
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/phonon-selfcheck.json"))
    }

    private static func openPane(_ key: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(key)") {
            NSWorkspace.shared.open(url)
        }
    }
}
