import AppKit
import CoreGraphics

/// Watches two global hotkeys via `flagsChanged`:
///   • Right Option (⌥) alone  → `onDictate`  (start/stop dictation — the main trigger)
///   • Fn (globe) alone         → `onEdit`     (voice-edit the current selection)
///
/// Fn is delivered as `.maskSecondaryFn`; we fire on the off→on transition and
/// require it to be the only modifier so app shortcuts (Fn+F1) don't trip it.
/// Right Option is matched by keycode (61) so it stays distinct from Fn.
final class HotkeyMonitor {
    var onDictate: (() -> Void)?
    var onEdit: (() -> Void)?
    var onCancel: (() -> Void)?            // Esc pressed

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnWasDown = false
    private var rightOptWasDown = false

    private static let kVKRightOption: Int64 = 61
    private static let kVKEscape: Int64 = 53

    static func dlog(_ m: String) {
        let line = m + "\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/phonon-hotkey.log") {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(toFile: "/tmp/phonon-hotkey.log", atomically: true, encoding: .utf8)
        }
    }

    func start() throws {
        HotkeyMonitor.dlog("start() called")
        let mask = CGEventMask((1 << CGEventType.flagsChanged.rawValue)
                               | (1 << CGEventType.keyDown.rawValue))

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: HotkeyMonitor.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            HotkeyMonitor.dlog("tapCreate FAILED (Input Monitoring not granted?)")
            throw NSError(
                domain: "HotkeyMonitor",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create event tap. Grant Input Monitoring permission."]
            )
        }
        HotkeyMonitor.dlog("tap installed OK")

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.runLoopSource = source
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == kVKEscape {
                DispatchQueue.main.async { monitor.onCancel?() }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)

            // --- Right Option alone → dictation (main trigger) ---
            let rightOptDown = flags.contains(.maskAlternate) && keycode == kVKRightOption
            let otherThanOpt: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskSecondaryFn]
            let onlyRightOpt = rightOptDown && flags.intersection(otherThanOpt).isEmpty
            if onlyRightOpt && !monitor.rightOptWasDown {
                monitor.rightOptWasDown = true
                HotkeyMonitor.dlog("right-⌥ down → onDictate")
                DispatchQueue.main.async { monitor.onDictate?() }
            } else if !flags.contains(.maskAlternate) {
                monitor.rightOptWasDown = false
            }

            // --- Fn alone → voice-edit selection ---
            let fnDown = flags.contains(.maskSecondaryFn)
            let nonFnMods: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
            let onlyFn = fnDown && flags.intersection(nonFnMods).isEmpty
            if onlyFn && !monitor.fnWasDown {
                monitor.fnWasDown = true
                DispatchQueue.main.async { monitor.onEdit?() }
            } else if !fnDown {
                monitor.fnWasDown = false
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
