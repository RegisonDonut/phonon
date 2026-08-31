import AppKit
import SwiftUI

/// Borderless, always-on-top floating window that hosts the waveform overlay
/// at the bottom-center of the active screen.
@MainActor
final class OverlayWindowController {
    private var window: NSWindow?
    private let state: OverlayState

    init(state: OverlayState) {
        self.state = state
    }

    func show() {
        if let window {
            window.orderFrontRegardless()
            return
        }

        let width: CGFloat = 280
        let height: CGFloat = 210
        let content = OverlayView(state: state)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let win = NSPanel(
            contentRect: host.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.isFloatingPanel = true
        win.level = .statusBar
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false   // the orb provides its own glow
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.contentView = host
        win.hidesOnDeactivate = false

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.midX - width / 2
            let y = frame.minY + 55
            win.setFrameOrigin(NSPoint(x: x, y: y))
        }

        win.orderFrontRegardless()
        self.window = win
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

enum OverlayPhase: Equatable {
    case recording
    case processing   // omni model: transcribe + clean in one pass
    case injecting
    case closing      // shrink + spin away
    case error(String)
}

enum OverlayMode: Equatable {
    case dictate
    case edit
}

@MainActor
final class OverlayState: ObservableObject {
    @Published var phase: OverlayPhase = .recording
    @Published var mode: OverlayMode = .dictate
    @Published var level: Float = 0
    @Published var closeAt: Date? = nil   // when the closing animation began
    @Published var statusTitle = "正在录音"
    @Published var statusDetail = "再次按快捷键结束"
}

struct OverlayView: View {
    @ObservedObject var state: OverlayState

    private var tint: SiriOrbView.OrbTint { state.mode == .edit ? .ember : .plasma }

    var body: some View {
        VStack(spacing: -5) {
            if case .error(let msg) = state.phase {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2).foregroundStyle(.yellow)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineLimit(3)
                }
                .padding(20)
                .frame(width: 160, height: 160)
            } else {
                // The orb is the whole UI: pulses with the voice while
                // recording, spins fast while thinking, spins away while closing.
                SiriOrbView(level: state.level, phase: orbPhase,
                            closeStart: state.closeAt, tint: tint)
                    .frame(width: 160, height: 160)
            }

            if showsStatus {
                VStack(spacing: 3) {
                    Text(state.statusTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(state.statusDetail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
            }
        }
        .frame(width: 280, height: 210)
    }

    private var orbPhase: SiriOrbView.Phase {
        switch state.phase {
        case .recording:               return .recording
        case .processing, .injecting:  return .thinking
        case .closing:                 return .closing
        case .error:                   return .thinking
        }
    }

    private var showsStatus: Bool {
        switch state.phase {
        case .recording, .processing, .injecting: return true
        case .closing, .error: return false
        }
    }
}
