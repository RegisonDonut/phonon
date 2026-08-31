# Phonon

A Typeless-style on-device dictation tool for macOS with two selectable local
inference pipelines. Press **Right ⌥**, speak, press **Right ⌥** again — the cleaned
text is pasted into the focused editable field. Press **Fn** with text selected to
edit it by voice.

## How it works

```
Right ⌥   →  record (AVAudioEngine, 16 kHz mono)  ─┐
                                                   ├─→  local MLX server  →  focused field / result card
Fn        →  grab selection + record command      ─┘   (MiniCPM-o or Qwen pipeline)
```

The menu bar lets you switch between **MiniCPM-o 4.5** for a lighter single-model
path and **Qwen3-ASR + Qwen3.5** for a higher-quality two-stage path. Both run
locally through MLX. The audio goes in with your personal vocabulary; polished
text comes out. Everything stays on-device.

Why MiniCPM-o: it's a small (~8B, 4-bit ≈ 5.7 GB) Chinese-first omni model with a
Whisper audio encoder — strong Chinese ASR, and the only small domestic omni
model with working audio support in current `mlx-vlm`. (Qwen2.5-Omni-3B has no
maintained MLX runtime; Qwen3-Omni is 30B.)

## Features (Typeless parity)

| Feature | How |
| --- | --- |
| **Dictation** | Right ⌥ to start/stop. Transcribe + clean in one model pass. |
| **Filler / repetition / self-correction removal** | Prompted into the model. |
| **Smart formatting** | Lists, steps, paragraphs auto-structured. |
| **Voice-edit a selection** | Select text, tap **Fn**, speak a command ("make it shorter", "更正式", "翻译成英文", "summarize this"). The selection is replaced with the result. |
| **Personal vocabulary** | `~/.config/phonon/vocabulary.txt`, one term per line. Re-read every dictation. |
| **App-aware tone** | Output style adapts to the frontmost app (email = formal, Slack/Telegram = casual, Xcode/VSCode = code). See `APP_STYLES` in `scripts/omni_server.py`. |
| **Screenshot keyword disambiguation** | While dictating, the screen is captured; if a spoken word phonetically matches an on-screen term, the original is kept and the screen spelling is added in parentheses, e.g. `沃克斯特拉（Voxtral）`. 3-stage + reconcile guard so it never corrupts the transcript. ~3s vs ~1s plain. Toggle: `~/.config/phonon/screenshot` (`0` to disable). |
| **Filler / particle cleanup** | Removes 嗯/呃/哦/唉, leading 是啊/对啊, and punctuation-delimited 那个/这个/就是 (conservative — keeps meaningful uses), on top of the model's own cleanup. |
| **Multilingual + translation** | Original language preserved on dictation; any language as an edit command. |
| **Private** | 100% local MLX inference. No network. |
| **Recoverable recordings** | Saves the latest 10 WAV recordings under `~/.config/phonon/recordings/` before transcription. Retry any item from the menu bar; successful retry results are copied to the clipboard. |
| **Safe focus fallback** | Pastes only when an editable field is focused. Otherwise a bottom-right result card offers Copy; before copying it stays open until closed, and after copying it becomes a 3-second Close countdown. |
| **Visible processing health** | The orb labels recording/save/model/injection stages and shows elapsed model time, whole-system CPU usage, and thermal throttling hints while transcription runs. |
| **Reliable long dictation** | Local requests have no wall-clock deadline. Qwen recordings over 75 seconds are split near natural pauses into ~60-second ASR chunks, then combined and formatted once as a complete transcript. |

## Requirements

- macOS on Apple Silicon (developed on M2 Max / 64 GB)
- **Xcode** (the app builds with the Xcode Swift toolchain — see note below)
- Python 3.12 (arm64) for the MLX server

## Install

```bash
# 1. Python env for the MLX server
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip \
  --trusted-host pypi.org --trusted-host files.pythonhosted.org   # if behind a TLS-MITM proxy
.venv/bin/python -m pip install mlx-vlm \
  --trusted-host pypi.org --trusted-host files.pythonhosted.org

# 2. Download the model (~5.7 GB)
.venv/bin/hf download mlx-community/MiniCPM-o-4_5-4bit \
  --local-dir models/MiniCPM-o-4_5-4bit

# 3. Build the .app  (uses the Xcode toolchain, NOT swiftly)
./scripts/bundle.sh
open build/Phonon.app

# 4. Run the model server (keeps MiniCPM-o warm)
./scripts/start_server.sh        # foreground, or install the launchd agent below
```

### Run the development server as a background service

```bash
./scripts/install_launch_agent.sh
```

The installer fills the launchd template with the current clone's absolute path.
It keeps the model warm, restarts on crash, and starts at login — so the menu-bar
app always has a server on `http://127.0.0.1:8799`. Packaged releases manage their
embedded server automatically and do not need this development setup.

First launch prompts for three permissions — grant all three:

| Permission | Why |
| --- | --- |
| Microphone | record audio |
| Input Monitoring | listen for Right ⌥ / Fn globally |
| Accessibility | synthesize ⌘C / ⌘V to read selections and paste |
| Screen Recording | capture the screen for keyword disambiguation (only if screenshot mode is on) |

> Ad-hoc signed: each rebuild changes the code hash, so macOS drops prior grants.
> If a hotkey/paste/screenshot stops working after a rebuild, run
> `tccutil reset ListenEvent|Accessibility|Microphone|ScreenCapture ai.donutbrowser.speech2text`,
> relaunch, and re-add the app via the **+** button in each pane.

## Performance (M2 Max, warm server)

| Audio length | End-to-end latency | Decode |
| --- | --- | --- |
| ~6 s | ~2.4 s | ~42 tok/s |
| ~18 s | ~3.6 s | ~30 tok/s |
| ~61 s | ~12 s | ~30 tok/s |

Model load is a one-time ~4 s (amortized by the warm server). Peak memory ≈ 7 GB.
Typical dictation utterances (5–20 s) land in **2–4 s**.

## Configuration

- **Model / port** — env vars `S2T_MODEL`, `S2T_PORT` (default `8799`), read by
  `scripts/start_server.sh` and the launchd plist. (Port 8799, not 8765, to
  avoid colliding with other local servers.)
- **Vocabulary** — `~/.config/phonon/vocabulary.txt`.
- **Per-app tone** — edit `APP_STYLES` in `scripts/omni_server.py`.
- **Hotkeys** — `Sources/Phonon/HotkeyMonitor.swift` (Right ⌥ = dictate, Fn = edit).

## Architecture

```
Right⌥ / Fn (CGEventTap)
      ↓
HotkeyMonitor → Coordinator ──┬─→ AudioRecorder   (AVAudioEngine, 16 kHz mono)
                              ├─→ OverlayWindow    (SwiftUI waveform panel)
                              ├─→ AudioFile        (samples → temp WAV)
                              ├─→ OmniClient ──HTTP──→ scripts/omni_server.py
                              │                         (MLX + MiniCPM-o 4.5)
                              │                         /dictate   /edit
                              ├─→ AppContext       (frontmost app → tone)
                              ├─→ Vocabulary       (personal dictionary)
                              └─→ TextInjector     (⌘C read selection, ⌘V paste)
```

State machine: `idle → recording → processing → idle`, in either `dictate` or
`edit` mode.

## Notes / gotchas

- **Build with Xcode's toolchain.** This machine also has a swiftly-installed
  Swift 6.x; its `swift-frontend` crashes (signal 6, `performSema`) against the
  current MacOSX SDK's module map. `scripts/bundle.sh` forces `/usr/bin/swift`.
- **TLS-MITM proxy.** If a system proxy (Shadowrocket/Clash) intercepts HTTPS,
  `pip`/`hf` need a CA bundle or `--trusted-host`. The model server itself is
  loopback-only and bypasses the proxy.
- **Short utterances** (< 0.25 s) are skipped.
