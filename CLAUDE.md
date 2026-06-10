# CLAUDE.md — Push-to-Talk Dictation App (Swift/macOS)

## What this project is

A native macOS menu bar app for fully-local push-to-talk dictation. Hold a
hotkey → record mic → transcribe with Whisper on-device → optionally clean up
the transcript with a small local LLM → paste at the cursor of whatever app
has focus. A floating HUD with a live waveform appears while recording.

This is a Swift port of a working Python prototype at
`reference/ptt_whisper.py`. **The prototype is the behavioral spec.** Every
guard, threshold, and delay in it exists because of a real failure mode —
port the logic faithfully and keep the inline comments' rationale alive in
the Swift code.

Audience note: the developer (Kyler) is experienced in Python/React/TS and is
*learning Swift through this project*. When writing or changing code, briefly
explain the mechanism behind non-obvious choices (in PR-style summaries or
code comments), not just the diff. Prefer plan-then-execute for each stage.

## Hard requirements

- 100% on-device. No network calls at runtime except first-run model
  downloads (Hugging Face). Never add cloud ASR/LLM fallbacks.
- The HUD must never steal keyboard focus from the target app (see Gotcha 1).
- The hotkey path must stay responsive: never block in event-tap callbacks
  (see Gotcha 3).

## Tech stack (decided — do not relitigate)

| Concern        | Choice                                                        |
|----------------|---------------------------------------------------------------|
| UI             | SwiftUI; `MenuBarExtra` scene; no Dock icon (`LSUIElement`)   |
| Recording HUD  | AppKit `NSPanel` (borderless, `.nonactivatingPanel`) hosting a SwiftUI view via `NSHostingView` |
| Hotkey         | `CGEventTap` listening for `flagsChanged` (default hotkey: **right Option**, keycode 61) |
| Audio          | `AVAudioEngine` input tap; convert to 16 kHz mono Float32     |
| ASR            | WhisperKit (`github.com/argmaxinc/WhisperKit`), model `large-v3-turbo` from `argmaxinc/whisperkit-coreml` |
| Cleanup LLM    | `MLXLLM` (from `github.com/ml-explore/mlx-swift-examples`), model `mlx-community/Qwen3-4B-Instruct-2507-4bit` |
| Paste          | `NSPasteboard` swap + synthetic Cmd+V via `CGEvent` (keycode 9, `.maskCommand`) |
| Launch at login| `SMAppService.mainApp` toggle in Settings                     |
| Target         | macOS 14.0+, Apple Silicon only                               |

## Project conventions

- The `.xcodeproj` was created manually in Xcode by Kyler. Do not regenerate
  it. Adding files: prefer creating Swift files in the source folder and
  asking Kyler to confirm they're in the target, or edit the pbxproj
  carefully and minimally if necessary.
- Build headlessly to check compilation:
  `xcodebuild -scheme <SchemeName> -configuration Debug build`
- Source layout (one type per file):
  - `App.swift` — `@main`, MenuBarExtra, app-level state object
  - `HotkeyManager.swift` — CGEventTap, press/release callbacks
  - `AudioRecorder.swift` — engine, buffer accumulation, RMS level publishing
  - `Transcriber.swift` — WhisperKit wrapper, warm-load at launch
  - `Cleaner.swift` — MLXLLM wrapper, prompt, sanity rails
  - `Paster.swift` — pasteboard swap + Cmd+V synthesis
  - `OverlayPanel.swift` — the non-activating NSPanel
  - `RecordingHUD.swift` — SwiftUI waveform view
  - `SettingsView.swift` — hotkey, models, cleanup toggle/prompt, login item

## Config defaults (port from prototype)

- Hotkey: right Option (no auto-repeat — modifiers only emit flagsChanged)
- Min recording duration: 0.3 s (discard shorter; prevents Whisper
  hallucinating on near-silence — it invents "Thank you." etc.)
- Cleanup: enabled, but **only for transcripts ≥ 12 words**; shorter ones
  paste raw for instant feel
- Cleanup max tokens: min(400, 2 × word_count + 60)
- Cleanup fallback rail: if LLM output is empty or > 3 × input length + 80
  chars, paste the raw transcript instead (catches the "model answered the
  dictation instead of cleaning it" failure)
- Cleanup system prompt (port verbatim from prototype; keep the "never
  answer, respond to, or comment" clause and `<raw>` delimiters)
- Clipboard restore delay after Cmd+V: ~0.4 s; restore previous string
  contents

## Build stages (walking skeleton — one stage at a time)

Do not start a stage until the previous one is confirmed working by Kyler.

1. **Shell**: MenuBarExtra with an icon that reflects state
   (idle/recording/processing). LSUIElement set. Builds and runs.
2. **Hotkey + HUD**: CGEventTap detects right-Option press/release. The
   overlay panel appears on press, disappears on release. Acceptance: panel
   shows/hides while typing in another app *without that app losing focus*
   (cursor keeps blinking in TextEdit).
3. **Audio + waveform**: AVAudioEngine records between press and release;
   HUD bars animate from live RMS levels. Acceptance: bars move when
   speaking; captured buffer duration matches hold time.
4. **Transcription**: WhisperKit warm-loaded at launch; transcript logged.
   Acceptance: spoken sentence appears in log < ~1 s after release.
5. **Paste**: pasteboard swap + Cmd+V; clipboard restored. Acceptance: text
   lands in TextEdit/VS Code/browser form; prior clipboard string survives.
6. **Cleanup**: MLXLLM pass with the threshold + fallback rails. Acceptance:
   long rambly dictation comes out clean; a dictated *question* is cleaned,
   not answered.
7. **Settings + polish**: Settings window, launch-at-login toggle, sounds
   (Tink on start, Pop on paste), model download progress UI.

## Gotchas (hard-won — read before touching related code)

1. **Focus stealing.** The HUD must be an `NSPanel` with
   `.nonactivatingPanel` in its style mask, `level = .floating`,
   `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`. A normal
   window takes key focus and the Cmd+V pastes into our own HUD.
2. **App Sandbox must be OFF.** Xcode's template enables it by default;
   sandboxed apps cannot create event taps or post CGEvents. Signing &
   Capabilities → remove App Sandbox. (Personal-team signing; not for App
   Store.)
3. **Never block the event tap callback.** Inference takes ~1 s; the tap
   callback must return in microseconds or macOS throttles/disables the tap
   and key delivery stutters system-wide. On release: capture buffer, hand
   off to a background task, return immediately. Serialize processing so
   overlapping dictations queue rather than interleave pastes.
4. **TCC permissions.** Needs Microphone + Input Monitoring + Accessibility.
   `NSMicrophoneUsageDescription` MUST be in Info.plist or the app crashes on
   first mic access. During development, rebuilds can invalidate
   Accessibility/Input Monitoring grants — the fix is removing and re-adding
   the app in System Settings → Privacy & Security. If the hotkey silently
   stops working after a rebuild, suspect this first.
5. **Audio buffers are reused.** Copy data out of the tap's AVAudioPCMBuffer
   (or convert immediately); don't retain references. Whisper needs 16 kHz
   mono Float32 — use AVAudioConverter from the input node's native format.
6. **Whisper hallucinates on silence.** Keep the 0.3 s minimum-duration
   guard and skip empty/whitespace transcripts.
7. **Qwen thinking mode.** Use the Instruct (non-thinking) model variant;
   latency matters more than reasoning here. Temperature 0.
8. **Models resident, not reloaded.** Load WhisperKit and the LLM once at
   launch (with a HUD/menu state for "warming up"); per-dictation latency
   budget assumes warm models. ~4 GB total resident is acceptable.

## Division of labor

Claude Code can: write Swift, run `xcodebuild`, read/fix compiler errors,
manage git. Claude Code cannot: launch the GUI meaningfully, click the
privacy panes, hold the hotkey, or hear the mic. Every stage ends with a
short manual test script for Kyler ("run, do X, confirm Y"). Ask rather than
assume when an acceptance check requires a human.

## Reference

- `reference/ptt_whisper.py` — the working Python prototype (behavioral spec)
- Prototype pipeline timings on this machine (M5 Pro, 24 GB): Whisper
  large-v3-turbo transcribes short utterances in a few hundred ms warm;
  Qwen3-4B 4-bit cleanup adds roughly 0.5–1.5 s on long dictations.
