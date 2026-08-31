import AppKit
import SwiftUI

/// First-run setup window: a small orb + a visible checklist and live model
/// download progress, so the person installing sees exactly what's happening.
@MainActor
final class SetupWindowController {
    private var window: NSWindow?
    private let state: SetupState

    init(state: SetupState) { self.state = state }

    func show() {
        if window != nil { return }
        let host = NSHostingView(rootView: SetupView(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 420)
        let win = NSWindow(contentRect: host.frame,
                           styleMask: [.titled, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "Phonon"
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.center()
        win.contentView = host
        win.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.level = .floating
        self.window = win
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

struct SetupView: View {
    @ObservedObject var state: SetupState

    var body: some View {
        VStack(spacing: 16) {
            SiriOrbView(level: 0.4, phase: orbPhase, tint: .plasma)
                .frame(width: 90, height: 90)
            Text("Phonon").font(.title2).bold()

            if state.phase == .choosing {
                picker
            } else {
                progress
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 440, height: state.phase == .choosing ? 420 : 320)
    }

    private var picker: some View {
        VStack(spacing: 12) {
            Text("选择要安装的语音模型").font(.subheadline).foregroundStyle(.secondary)
            ForEach(Models.all) { spec in
                Button { state.onChoose?(spec) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(spec.name).font(.headline)
                            Spacer()
                            Text(String(format: "%.1f GB", spec.approxGB))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(spec.blurb).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            Text("装好后可随时在菜单栏的球图标里切换/再装另一个。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var progress: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                row("准备运行环境", done: stepDone(0), active: isStep(0))
                row("下载语音模型", done: stepDone(1), active: isStep(1))
                row("启动本地服务", done: stepDone(2), active: isStep(2))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if case .downloading = state.phase {
                VStack(spacing: 4) {
                    ProgressView(value: state.fraction)
                    Text(state.detail).font(.caption2).foregroundStyle(.secondary)
                }
            } else if case .error(let msg) = state.phase {
                Text(msg).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            } else if state.phase == .ready {
                Text("就绪 — 按一下右 ⌥ 开始说话").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var orbPhase: SiriOrbView.Phase {
        state.phase == .ready ? .recording : .thinking
    }

    @ViewBuilder private func row(_ title: String, done: Bool, active: Bool) -> some View {
        HStack(spacing: 10) {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if active {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
            } else {
                Image(systemName: "circle").foregroundStyle(.secondary.opacity(0.5))
            }
            Text(title).foregroundStyle(active || done ? .primary : .secondary)
            Spacer()
        }
    }

    private func stepIndex() -> Int {
        switch state.phase {
        case .choosing: return -1
        case .preparing: return 0
        case .downloading: return 1
        case .startingServer: return 2
        case .ready: return 3
        case .error: return -1
        }
    }
    private func isStep(_ i: Int) -> Bool { stepIndex() == i }
    private func stepDone(_ i: Int) -> Bool { stepIndex() > i }
}
