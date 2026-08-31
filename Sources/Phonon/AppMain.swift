import AppKit
import IOKit.hid

@main
@MainActor
final class AppMain: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var coordinator: Coordinator?
    private var statusItem: NSStatusItem?
    /// Model folder the live server reports loading (truth, vs on-disk config).
    private var liveModelFolder: String?
    private let server = ServerManager()
    private let setup = SetupState()
    private lazy var setupWindow = SetupWindowController(state: setup)

    static func main() {
        let app = NSApplication.shared
        let delegate = AppMain()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu-bar only, no dock icon
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Proactively pop the native permission prompts (mic / input monitoring
        // / accessibility) so the user isn't left hunting in System Settings.
        Permissions.requestAtLaunch()
        installStatusItem()
        let c = Coordinator()
        c.onRecordingsChanged = { [weak self] in self?.rebuildMenu() }
        c.onRetrySucceeded = { [weak self] text in self?.recordingRetrySucceeded(text) }
        c.onRetryFailed = { [weak self] message in
            self?.statusItem?.button?.title = ""
            self?.showRecordingAlert(title: "转译失败", message: message, success: false)
        }
        c.start()                 // hotkeys live; dictation works once server is up
        self.coordinator = c
        // Report the real grant state a moment after launch (TCC answers are
        // only meaningful once the app is fully up).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Permissions.writeSelfCheck()
            self.rebuildMenu()
        }
        Task { await bootstrap() }
    }

    /// First run with nothing installed → let the user pick a model. Otherwise
    /// just bring up the active model.
    @MainActor private func bootstrap() async {
        if !Models.hasChosen && !AppPaths.modelReady(Models.active) {
            setup.onChoose = { [weak self] spec in
                guard let self else { return }
                self.setup.onChoose = nil
                Models.setActive(spec)
                self.rebuildMenu()
                Task { await self.proceed() }
            }
            setup.phase = .choosing
            setupWindow.show()
            return
        }
        await proceed()
    }

    /// Download the active model (with progress) if missing, then start server.
    @MainActor private func proceed() async {
        let active = Models.active
        if !AppPaths.modelReady(active) {
            setup.fraction = 0; setup.phase = .downloading
            setupWindow.show()
            guard await ModelDownloader(state: setup).run(active) else { return }
        }
        setup.phase = .startingServer
        let ok = await server.ensureRunning()
        if ok {
            setup.phase = .ready
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            setupWindow.close()
        } else {
            setup.phase = .error("本地服务启动失败，请重开 Phonon 重试。")
        }
        rebuildMenu()
        refreshLiveModel()
    }

    /// Switch to another model: download if needed (with progress), then restart
    /// the server on the new model.
    @MainActor private func switchModel(to spec: ModelSpec) {
        if spec.id == Models.active.id { return }
        Models.setActive(spec)
        rebuildMenu()
        Task {
            if !AppPaths.modelReady(spec) {
                setup.fraction = 0; setup.phase = .downloading; setupWindow.show()
                guard await ModelDownloader(state: setup).run(spec) else { rebuildMenu(); return }
            }
            setup.phase = .startingServer; setupWindow.show()
            let ok = await server.restart()
            setup.phase = ok ? .ready : .error("切换失败，请重试。")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            setupWindow.close()
            rebuildMenu()
            refreshLiveModel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let img = NSImage(named: "MenuBarOrb") {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = false
                button.image = img
            } else {
                button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "Phonon")
            }
        }
        self.statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Right ⌥ — 听写", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Fn — 选中改写", action: nil, keyEquivalent: ""))

        // A missing Input Monitoring grant kills the hotkey silently (the event
        // tap is created but never fires), so surface it instead of looking dead.
        if !Permissions.inputMonitoringGranted {
            let warn = NSMenuItem(title: "⚠️ 缺「输入监控」权限 → 快捷键不工作，点这里开设置",
                                  action: #selector(fixInputMonitoring), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }
        if !Permissions.accessibilityGranted {
            let warn = NSMenuItem(title: "⚠️ 缺「辅助功能」权限 → 无法自动粘贴，点这里开设置",
                                  action: #selector(fixAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }
        menu.addItem(.separator())

        let configActive = Models.active
        // Trust what the server actually loaded over the on-disk config: the two
        // can drift (orphan/duplicate server processes), and showing the config
        // value then would lie about which model is really serving requests.
        let liveActive = liveModelFolder.flatMap { lm in
            Models.all.first { lm.hasSuffix($0.folder) }
        }
        let active = liveActive ?? configActive
        // Header shows the model in use right now, at a glance.
        let header = NSMenuItem(title: "当前模型：\(active.name)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let live = liveActive, live.id != configActive.id {
            let warn = NSMenuItem(title: "⚠️ 配置选的是 \(configActive.name)，重启可对齐", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        let hint = NSMenuItem(title: "点下面任意一个即可一键切换：", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        for spec in Models.all {
            let isActive = (spec.id == active.id)
            let installed = AppPaths.modelReady(spec)
            let state: String
            if isActive { state = "  ✓ 使用中" }
            else if !installed { state = "  ↓需下载 \(String(format: "%.1f", spec.approxGB))GB" }
            else { state = "  ← 点击切换" }
            let mi = NSMenuItem(title: "\(spec.name)\(state)", action: #selector(modelClicked(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = spec.id
            mi.state = isActive ? .on : .off          // checkmark on active
            mi.toolTip = spec.blurb
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let kw = NSMenuItem(title: "✏️ 编辑关键词…", action: #selector(editVocabulary), keyEquivalent: "")
        kw.target = self
        kw.toolTip = "编辑听写自定义词表（每个人各自的，存盘即生效）"
        menu.addItem(kw)
        let cr = NSMenuItem(title: "🔧 编辑纠正词…", action: #selector(editCorrections), keyEquivalent: "")
        cr.target = self
        cr.toolTip = "编辑听写纠正表：把老被听错的固定词替换成正确写法（存盘即生效）"
        menu.addItem(cr)

        menu.addItem(.separator())
        let rr = NSMenuItem(title: "🎙 最近录音（10 条）", action: nil, keyEquivalent: "")
        rr.toolTip = "录音会保存在本机；转译失败时可在这里重试"
        rr.submenu = makeRecordingMenu()
        menu.addItem(rr)

        let hh = NSMenuItem(title: "📋 最近转录", action: nil, keyEquivalent: "")
        hh.toolTip = "鼠标移上去展开最近的转录，点一条即复制全文"
        hh.submenu = makeHistoryMenu()
        menu.addItem(hh)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Phonon", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
    }

    // MARK: - Transcript history

    /// Hover-to-open submenu — keeping the (up to 25) transcripts out of the
    /// main menu so it stays short and 退出 doesn't get pushed off screen.
    /// Rebuilt on each open via `menuNeedsUpdate`, so the line you just dictated
    /// is already there.
    /// A fresh NSMenu per rebuild: an NSMenu may only ever hang off ONE menu
    /// item, so reusing one instance across `rebuildMenu()` calls trips an
    /// AppKit assertion in `-[NSMenuItem setSubmenu:]` and aborts the app.
    private weak var historyMenu: NSMenu?
    private weak var recordingMenu: NSMenu?

    private func makeHistoryMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        historyMenu = m
        return m
    }

    private func makeRecordingMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        recordingMenu = m
        return m
    }

    /// NSMenuDelegate — refresh the submenu right before it's shown.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === recordingMenu {
            rebuildRecordingMenu(menu)
            return
        }
        guard menu === historyMenu else { return }
        menu.removeAllItems()
        let entries = History.load()
        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: "（还没有转录记录）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let hint = NSMenuItem(title: "点一条即复制全文：", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        for entry in entries {
            let mi = NSMenuItem(title: "\(History.preview(entry.text))   ⧉",
                                action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = entry.text
            mi.toolTip = String(entry.text.prefix(600))
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "🗑 清空转录记录", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    private func rebuildRecordingMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = RecordingStore.load()
        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: "（还没有保存的录音）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let hint = NSMenuItem(title: "录音保留最新 10 条，可随时重试：", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        for entry in entries {
            menu.addItem(recordingMenuItem(entry))
        }
    }

    /// A custom native menu row lets the timestamp/status and retry button sit
    /// beside each other instead of making the whole row an ambiguous action.
    private func recordingMenuItem(_ entry: RecordingStore.Entry) -> NSMenuItem {
        let item = NSMenuItem()
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 32))

        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        let status = entry.transcript == nil ? "待转译" : "已转译"
        let label = NSTextField(labelWithString:
            "\(formatter.string(from: entry.date))  \(formatDuration(entry.duration))  · \(status)")
        label.frame = NSRect(x: 12, y: 7, width: 235, height: 18)
        label.lineBreakMode = .byTruncatingTail
        row.addSubview(label)

        let button = NSButton(title: entry.transcript == nil ? "转译" : "重新转译",
                              target: self, action: #selector(retryRecording(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.frame = NSRect(x: 250, y: 4, width: 82, height: 24)
        button.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
        row.addSubview(button)
        item.view = row
        return item
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @objc private func retryRecording(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let id = UUID(uuidString: raw) else { return }
        recordingMenu?.cancelTracking()
        statusItem?.button?.title = " 转译中…"
        coordinator?.retryRecording(id: id)
    }

    private func recordingRetrySucceeded(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        flashCopied()
        showRecordingAlert(title: "转译成功",
                           message: "文字已放入剪贴板，可以直接粘贴。",
                           success: true)
    }

    private func showRecordingAlert(title: String, message: String, success: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = success ? .informational : .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        flashCopied()
    }

    /// Brief "✓ 已复制" next to the menu-bar icon — the clipboard is invisible,
    /// so without it there's no sign the click did anything.
    private func flashCopied() {
        guard let button = statusItem?.button else { return }
        button.title = " ✓ 已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak button] in
            button?.title = ""
        }
    }

    @objc private func clearHistory() {
        History.clear()
    }

    @objc private func fixInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)   // re-prompt if possible
        Permissions.openInputMonitoring()
    }

    @objc private func fixAccessibility() {
        Permissions.openAccessibility()
    }

    /// Open the per-user custom-vocabulary file in a text editor, seeding a
    /// commented template on first use. The file lives in ~/.config (never
    /// bundled into the .app), so each user keeps their own terms.
    @objc private func editVocabulary() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/phonon/vocabulary.txt")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            let template = """
            # Phonon 听写自定义词表 / custom vocabulary
            # 一行一个词；# 开头是注释；保存后下一句听写即生效。
            # 把你常说、但容易被听错的英文术语 / 专有名词写在这里，例如：
            # Polymarket
            # HyperLiquid
            # Backend

            """
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        openInEditor(url)
    }

    /// Open the per-user corrections file (misheard => intended replacements),
    /// seeding a commented template on first use.
    @objc private func editCorrections() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/phonon/corrections.txt")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            let template = """
            # Phonon 听写纠正表 / corrections
            # 一行一条：把「听错的固定写法」替换成「你想要的写法」。
            # 格式：  听错的 => 正确的      （# 开头是注释；保存后下一句即生效）
            # 适合修「发音不标准、ASR 总听成同一个错词」的情况，是每个人各自的。例如：
            # 零零一九 => Linear Issue

            """
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        openInEditor(url)
    }

    /// Ensure the file's folder exists, then open it in the default text editor.
    private func openInEditor(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", url.path]   // -t: open in the default text editor
        try? p.run()
    }

    /// Ask the live server which model it loaded and redraw the menu so the
    /// header reflects reality, not just the on-disk config.
    @MainActor private func refreshLiveModel() {
        Task {
            liveModelFolder = await server.reportedModel()
            rebuildMenu()
        }
    }

    @objc private func modelClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        switchModel(to: Models.spec(id: id))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
