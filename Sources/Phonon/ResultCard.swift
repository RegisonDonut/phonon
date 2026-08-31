import AppKit
import SwiftUI

/// Persistent bottom-right fallback shown when transcription finishes without
/// an editable field focused. Before copying it only closes via the × button;
/// after copying, the action becomes Close and a three-second countdown starts.
@MainActor
final class ResultCardController {
    private var window: NSPanel?
    private let state = ResultCardState()
    private var autoCloseTask: Task<Void, Never>?

    func show(text: String) {
        autoCloseTask?.cancel()
        autoCloseTask = nil
        state.text = text
        state.copied = false
        state.closeCountdown = 0

        if let window {
            position(window)
            window.orderFrontRegardless()
            return
        }

        let size = NSSize(width: 390, height: 230)
        let content = ResultCardView(
            state: state,
            onCopy: { [weak self] in self?.copyText() },
            onClose: { [weak self] in self?.hide() }
        )
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: host.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = host
        position(panel)
        panel.orderFrontRegardless()
        window = panel
    }

    private func copyText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(state.text, forType: .string)
        state.copied = true
        state.closeCountdown = 3
        autoCloseTask?.cancel()
        autoCloseTask = Task { [weak self] in
            for remaining in [2, 1] {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.state.closeCountdown = remaining
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        autoCloseTask?.cancel()
        autoCloseTask = nil
        window?.orderOut(nil)
        window = nil
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - panel.frame.width - 20,
            y: frame.minY + 20
        ))
    }
}

@MainActor
private final class ResultCardState: ObservableObject {
    @Published var text = ""
    @Published var copied = false
    @Published var closeCountdown = 0
}

private struct ResultCardView: View {
    @ObservedObject var state: ResultCardState
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                appLogo
                VStack(alignment: .leading, spacing: 1) {
                    Text("Phonon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("转译完成")
                        .font(.headline)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            Text("未检测到正在输入的文本框，内容已安全保存。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(state.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 105)

            HStack {
                Spacer()
                Button(action: state.copied ? onClose : onCopy) {
                    Label(state.copied ? "关闭（\(state.closeCountdown)）" : "复制内容",
                          systemImage: state.copied ? "xmark" : "doc.on.doc")
                        .frame(minWidth: 82)
                }
                .keyboardShortcut("c", modifiers: [.command])
            }
        }
        .padding(16)
        .frame(width: 390, height: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var appLogo: some View {
        if let image = NSImage(named: "MenuBarOrb") {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
        } else {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.purple)
        }
    }
}
