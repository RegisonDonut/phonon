import AppKit
import ApplicationServices
import CoreGraphics

/// Injects text into the currently active app by swapping the clipboard
/// and dispatching Cmd+V. This is the same technique Raycast, Rcmd and
/// similar productivity apps use — text fields don't expose an "insert
/// text" API across the process boundary.
enum TextInjector {
    enum FocusState: String {
        case editable
        case notEditable
        case unknown
    }

    /// Whether the frontmost app currently exposes a focused editable text
    /// control through macOS Accessibility. This prevents Cmd+V from being
    /// dispatched into a random window after the user changes apps while the
    /// model is still working.
    static func editableFocusState() -> FocusState {
        guard AXIsProcessTrusted() else { return .unknown }
        let system = AXUIElementCreateSystemWide()
        var rawElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &rawElement
        ) == .success, let rawElement else {
            NSLog("focus check: no AX focused element (unknown)")
            return .unknown
        }
        let element = unsafeBitCast(rawElement, to: AXUIElement.self)

        let state = editableState(of: element, depth: 0)
        NSLog("focus check: role=%@ state=%@",
              stringAttribute(kAXRoleAttribute as String, from: element) ?? "?",
              state.rawValue)
        return state
    }

    /// Native fields normally expose AXTextField/AXTextArea. Chromium and
    /// Electron may instead focus a wrapper and expose the real contenteditable
    /// node via AXEditableAncestor or AXActiveElement, so follow those links.
    private static func editableState(of element: AXUIElement, depth: Int) -> FocusState {
        guard depth < 4 else { return .unknown }

        var enabledValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXEnabledAttribute as CFString, &enabledValue
        ) == .success, let enabled = enabledValue as? Bool, !enabled {
            return .notEditable
        }

        let role = stringAttribute(kAXRoleAttribute as String, from: element)
        let textRoles = [kAXTextFieldRole as String,
                         kAXTextAreaRole as String,
                         kAXComboBoxRole as String]
        // Some apps report AXValue as read-only even though Cmd+V is accepted;
        // the focused, enabled text role is the more reliable signal.
        if let role, textRoles.contains(role) { return .editable }

        // Generic/custom controls can still be editors. Requiring both a text
        // selection attribute and a writable value avoids treating sliders and
        // checkboxes (which also have writable AXValue) as text inputs.
        var attributeNames: CFArray?
        if AXUIElementCopyAttributeNames(element, &attributeNames) == .success,
           let names = attributeNames as? [String],
           names.contains(kAXSelectedTextRangeAttribute as String) ||
           names.contains(kAXSelectedTextAttribute as String) {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(
                element, kAXValueAttribute as CFString, &settable
            ) == .success, settable.boolValue {
                return .editable
            }
        }

        for attribute in ["AXEditableAncestor", "AXHighestEditableAncestor", "AXActiveElement"] {
            var rawRelated: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, attribute as CFString, &rawRelated
            ) == .success, let rawRelated else { continue }
            let related = unsafeBitCast(rawRelated, to: AXUIElement.self)
            let relatedState = editableState(of: related, depth: depth + 1)
            if relatedState == .editable { return .editable }
        }

        // Only return a definite negative for controls that clearly cannot be
        // text editors. Custom web/Electron roles remain unknown because many
        // of them still accept Cmd+V despite incomplete AX metadata.
        let definitelyNonTextRoles = [
            kAXButtonRole as String, kAXCheckBoxRole as String,
            kAXRadioButtonRole as String, kAXSliderRole as String,
            kAXMenuItemRole as String, kAXStaticTextRole as String,
            kAXImageRole as String
        ]
        if let role, definitelyNonTextRoles.contains(role) { return .notEditable }
        return .unknown
    }

    private static func stringAttribute(_ attribute: String,
                                        from element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &raw
        ) == .success else { return nil }
        return raw as? String
    }

    static func insert(_ text: String) {
        guard !text.isEmpty else { return }

        let pb = NSPasteboard.general
        // Preserve current clipboard (first item only; good enough for text workflows).
        let saved = pb.pasteboardItems?.compactMap { item -> [String: String]? in
            var dict: [String: String] = [:]
            for type in item.types {
                if let s = item.string(forType: type) {
                    dict[type.rawValue] = s
                }
            }
            return dict.isEmpty ? nil : dict
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChangeCount = pb.changeCount

        // Let the clipboard write settle before synthesizing ⌘V, otherwise a
        // fast target app can paste the *previous* clipboard contents.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            sendCommandV()
        }

        // Restore the previous clipboard, but only after the paste has had time
        // to complete (0.7 s — 0.3 s raced and pasted stale clipboard content),
        // and only if nothing else has written to the clipboard since (otherwise
        // we'd clobber newer content).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard pb.changeCount == ourChangeCount else { return }
            pb.clearContents()
            if let saved {
                for entry in saved {
                    let item = NSPasteboardItem()
                    for (type, value) in entry {
                        item.setString(value, forType: NSPasteboard.PasteboardType(type))
                    }
                    pb.writeObjects([item])
                }
            }
        }
    }

    /// Reads the active app's current text selection by synthesizing ⌘C and
    /// sampling the pasteboard. Returns nil if nothing is selected. Restores
    /// the previous clipboard afterward. Used by voice-edit mode.
    static func copySelection() -> String? {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let saved = pb.string(forType: .string)

        sendCommand(key: 8)  // kVK_ANSI_C = 8
        // Give the frontmost app a moment to service the copy.
        let deadline = Date().addingTimeInterval(0.4)
        while pb.changeCount == before && Date() < deadline {
            usleep(15_000)
        }
        let copied = pb.changeCount != before ? pb.string(forType: .string) : nil

        // Restore prior clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }
        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return copied
    }

    private static func sendCommandV() { sendCommand(key: 9) }  // kVK_ANSI_V = 9

    private static func sendCommand(key: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
