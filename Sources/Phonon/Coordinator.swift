import AppKit
import Combine
import Foundation

/// State machine wiring the two hotkeys to the single omni model:
///
///   Fn          → dictation:   record → omni /dictate → paste cleaned text
///   Right Option → voice-edit:  grab selection → record command →
///                               omni /edit → paste transformed text
///
/// Both modes go through one MiniCPM-o pass (transcribe + clean together),
/// replacing the old whisper.cpp + Ollama two-model pipeline.
@MainActor
final class Coordinator {
    var onRecordingsChanged: (() -> Void)?
    var onRetrySucceeded: ((String) -> Void)?
    var onRetryFailed: ((String) -> Void)?

    private enum State: CustomStringConvertible {
        case idle
        case recording
        case processing
        var description: String {
            switch self {
            case .idle: return "idle"
            case .recording: return "recording"
            case .processing: return "processing"
            }
        }
    }

    private var state: State = .idle
    private var mode: OverlayMode = .dictate
    private var pendingSelection: String?
    // Screenshot + native OCR kicked off at record-start so it runs *during*
    // speech (parallel) and never delays sending.
    private var pendingKeywords: Task<[String], Never>?
    private var processingTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var processingStatusTask: Task<Void, Never>?

    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let omni = OmniClient()
    private let overlayState = OverlayState()
    private lazy var overlay = OverlayWindowController(state: overlayState)
    private lazy var resultCard = ResultCardController()
    private var levelObservation: AnyCancellable?
    private let systemLoad = SystemLoadMonitor()

    private var hotkeyRetry: Timer?

    func start() {
        hotkey.onDictate = { [weak self] in self?.toggleDictate() }
        hotkey.onEdit = { [weak self] in self?.toggleEdit() }
        hotkey.onCancel = { [weak self] in self?.cancel() }
        installHotkey()
        levelObservation = recorder.$level.sink { [weak self] newLevel in
            self?.overlayState.level = newLevel
        }
    }

    /// Installs the global hotkey tap. If Input Monitoring isn't granted yet
    /// the tap can't be created — so we open the pane and keep retrying, so it
    /// starts working the moment the user flips the switch (no relaunch needed).
    private func installHotkey() {
        do {
            try hotkey.start()
            hotkeyRetry?.invalidate(); hotkeyRetry = nil
        } catch {
            guard hotkeyRetry == nil else { return }
            Permissions.openInputMonitoring()
            hotkeyRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                if Permissions.inputMonitoringGranted, (try? self.hotkey.start()) != nil {
                    timer.invalidate(); self.hotkeyRetry = nil
                }
            }
        }
    }

    /// Esc — abort the current dictation: stop recording (or cancel the in-flight
    /// transcription) and dismiss, with no transcription/paste.
    private func cancel() {
        switch state {
        case .recording:
            _ = recorder.stop()          // discard samples
            pendingKeywords?.cancel(); pendingKeywords = nil
            dismissNow()
        case .processing:
            processingTask?.cancel()
            dismissNow()
        case .idle:
            break
        }
    }

    private func dismissNow() {
        stopProcessingStatus()
        overlay.hide()
        overlayState.phase = .recording
        state = .idle
    }

    // MARK: - Hotkey handlers

    private func toggleDictate() {
        HotkeyMonitor.dlog("toggleDictate: state=\(state) mode=\(mode)")
        switch state {
        case .idle:      beginRecording(mode: .dictate)
        case .recording where mode == .dictate: endRecording()
        default: break  // ignore Fn while editing or processing
        }
    }

    private func toggleEdit() {
        switch state {
        case .idle:
            // Capture the current selection before recording the spoken command.
            guard let selection = TextInjector.copySelection() else {
                showError("Select some text first, then press Fn.")
                return
            }
            pendingSelection = selection
            beginRecording(mode: .edit)
        case .recording where mode == .edit:
            endRecording()
        default: break  // ignore Right ⌥ while dictating or processing
        }
    }

    // MARK: - Recording

    private func beginRecording(mode: OverlayMode) {
        do {
            try recorder.start()
            self.mode = mode
            overlayState.mode = mode
            overlayState.phase = .recording
            overlayState.level = 0
            overlayState.statusTitle = mode == .dictate ? "正在录音" : "正在录制改写指令"
            overlayState.statusDetail = "再次按快捷键结束"
            overlay.show()
            state = .recording
            // Fire screenshot + OCR now, in parallel with speaking.
            if mode == .dictate, Settings.screenshotEnabled {
                if !Permissions.screenRecordingGranted { Permissions.requestScreenRecording() }
                pendingKeywords = Task.detached(priority: .userInitiated) {
                    guard let shot = ScreenCapture.grab() else { return [] }
                    defer { try? FileManager.default.removeItem(at: shot) }
                    return ScreenOCR.keywords(from: shot)
                }
            } else {
                pendingKeywords = nil
            }
        } catch {
            HotkeyMonitor.dlog("recorder.start FAILED: \(error)")
            showError("Mic error: \(error.localizedDescription)")
        }
    }

    private func endRecording() {
        let samples = recorder.stop()
        state = .processing
        overlayState.phase = .processing
        overlayState.statusTitle = "正在保存录音"
        overlayState.statusDetail = "录音已保护，不会因转译失败丢失"
        let currentMode = mode
        let selection = pendingSelection
        pendingSelection = nil

        processingTask = Task {
            do {
                try Task.checkCancellation()
                // <0.25s of audio: nothing meaningful was said.
                guard samples.count > 16_000 / 4 else {
                    self.finish()
                    return
                }
                let context = DictationContext(
                    appBundleID: AppContext.frontmostBundleID(),
                    vocabulary: Vocabulary.load(),
                    language: "auto"
                )
                // Persist first. The WAV remains available even if everything
                // after this point fails or the task is cancelled.
                let recording = try RecordingStore.add(
                    samples: samples,
                    kind: currentMode == .dictate ? .dictate : .edit,
                    selectedText: selection,
                    appBundleID: context.appBundleID
                )
                self.onRecordingsChanged?()
                let wav = RecordingStore.audioURL(for: recording)
                self.overlayState.statusTitle = "等待本地模型"
                self.overlayState.statusDetail = "正在准备转译请求"

                let result: OmniClient.Result
                self.startProcessingStatus()
                switch currentMode {
                case .dictate:
                    // Screen keywords were OCR'd in parallel during recording;
                    // just collect them (no extra latency on the critical path).
                    let keywords = await (pendingKeywords?.value ?? [])
                    RecordingStore.setScreenKeywords(keywords, for: recording.id)
                    result = try await omni.dictate(wav: wav, screenKeywords: keywords, context: context)
                case .edit:
                    result = try await omni.edit(wav: wav, selectedText: selection ?? "", context: context)
                }

                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    self.finish()
                    return
                }
                NSLog("omni %@: %.2fs, %@ tok @ %@ tok/s",
                      currentMode == .edit ? "edit" : "dictate",
                      result.elapsed,
                      result.genTokens.map(String.init) ?? "?",
                      result.genTPS.map { String(format: "%.1f", $0) } ?? "?")

                await MainActor.run {
                    self.overlayState.phase = .injecting
                    self.stopProcessingStatus()
                    self.overlayState.statusTitle = "转译完成"
                    self.overlayState.statusDetail = "正在写入结果"
                    // Record before pasting: if no field is focused the text goes
                    // nowhere, and the menu-bar history is the only way back.
                    RecordingStore.setTranscript(text, for: recording.id)
                    History.add(text)
                    self.onRecordingsChanged?()
                    let currentApp = AppContext.frontmostBundleID()
                    let focusState = TextInjector.editableFocusState()
                    let stayedInSameApp = currentApp == context.appBundleID
                    if focusState == .editable ||
                       (focusState == .unknown && stayedInSameApp) {
                        NSLog("paste decision: paste focus=%@ sameApp=%@ app=%@",
                              focusState.rawValue, stayedInSameApp ? "yes" : "no",
                              currentApp ?? "?")
                        TextInjector.insert(text)
                    } else {
                        NSLog("paste decision: card focus=%@ sameApp=%@ start=%@ current=%@",
                              focusState.rawValue, stayedInSameApp ? "yes" : "no",
                              context.appBundleID ?? "?", currentApp ?? "?")
                        // The user may have changed windows while the model was
                        // working. Keep the result visible and copyable instead
                        // of pasting it into an unrelated place.
                        self.resultCard.show(text: text)
                    }
                    // Paste beat → shrink-and-spin-away → hide.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.dismissWithCloseAnimation()
                    }
                }
            } catch is CancellationError {
                self.stopProcessingStatus()
                // Esc-cancelled — dismissNow() already handled the UI.
            } catch {
                self.stopProcessingStatus()
                if (error as? URLError)?.code == .cancelled { return }
                await MainActor.run {
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    /// Retry a durable recording from the menu. The result is deliberately not
    /// injected into the frontmost app: AppMain copies it to the clipboard and
    /// confirms success, which avoids overwriting text in an unrelated window.
    func retryRecording(id: UUID) {
        guard case .idle = state else {
            onRetryFailed?("请先结束当前录音或转译，再重试历史录音。")
            return
        }
        guard retryTask == nil else {
            onRetryFailed?("已有一条录音正在转译，请稍候。")
            return
        }
        guard let entry = RecordingStore.entry(id: id) else {
            onRetryFailed?("找不到这条录音记录。")
            return
        }
        let wav = RecordingStore.audioURL(for: entry)
        guard FileManager.default.fileExists(atPath: wav.path) else {
            onRetryFailed?("录音文件不存在，无法重试。")
            return
        }

        retryTask = Task {
            defer { retryTask = nil }
            do {
                let context = DictationContext(
                    appBundleID: entry.appBundleID,
                    vocabulary: Vocabulary.load(),
                    language: "auto"
                )
                let result: OmniClient.Result
                switch entry.kind {
                case .dictate:
                    result = try await omni.dictate(
                        wav: wav, screenKeywords: entry.screenKeywords, context: context)
                case .edit:
                    result = try await omni.edit(
                        wav: wav, selectedText: entry.selectedText ?? "", context: context)
                }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw NSError(domain: "RecordingRetry", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "转译结果为空。"])
                }
                RecordingStore.setTranscript(text, for: id)
                History.add(text)
                onRecordingsChanged?()
                onRetrySucceeded?(text)
            } catch {
                if (error as? URLError)?.code != .cancelled {
                    onRetryFailed?(error.localizedDescription)
                }
            }
        }
    }

    private func finish() {
        stopProcessingStatus()
        dismissWithCloseAnimation()
    }

    private func startProcessingStatus() {
        processingStatusTask?.cancel()
        systemLoad.reset()
        let startedAt = Date()
        overlayState.statusTitle = "模型转译中 · 0 秒"
        overlayState.statusDetail = "系统 CPU 采样中"
        processingStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let elapsed = Int(Date().timeIntervalSince(startedAt))
                let cpu = self.systemLoad.cpuPercent()
                self.overlayState.statusTitle = "模型转译中 · \(elapsed) 秒"
                var details: [String] = []
                if let cpu { details.append("系统 CPU \(cpu)%") }
                if let thermal = SystemLoadMonitor.thermalDescription { details.append(thermal) }
                if let cpu, cpu >= 85, SystemLoadMonitor.thermalDescription == nil {
                    details.append("资源占用较高")
                }
                self.overlayState.statusDetail = details.isEmpty ? "正在等待模型返回" : details.joined(separator: " · ")
            }
        }
    }

    private func stopProcessingStatus() {
        processingStatusTask?.cancel()
        processingStatusTask = nil
    }

    /// Plays the orb's shrink-and-spin-away animation, then hides and resets.
    private func dismissWithCloseAnimation() {
        stopProcessingStatus()
        overlayState.closeAt = Date()         // deterministic close start for the orb
        overlayState.phase = .closing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.overlay.hide()
            self.overlayState.phase = .recording  // reset for next time
            self.overlayState.closeAt = nil
            self.state = .idle
        }
    }

    // MARK: - Errors

    private func showError(_ message: String) {
        overlayState.phase = .error(message)
        overlay.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.overlay.hide()
            self.state = .idle
        }
    }

}
