# PushToTalk

Fully local push-to-talk dictation for macOS (Apple Silicon). Hold a hotkey,
speak, release — your words are transcribed on-device and pasted at the
cursor of whatever app you're in. Nothing ever leaves the machine.

Hold **right Option** (configurable: right Cmd / right Ctrl / Fn) →
mic records with a floating waveform HUD → [WhisperKit](https://github.com/argmaxinc/WhisperKit)
(large-v3-turbo) transcribes → dictations of 12+ words are optionally tidied
by a local LLM (Qwen3-4B via [MLX](https://github.com/ml-explore/mlx-swift-lm)) —
fillers removed, punctuation fixed, never answered or rewritten → pasted via
clipboard swap + synthetic Cmd+V, with your previous clipboard restored.

Ported from a working Python prototype (`reference/ptt_whisper.py`), which
remains the behavioral spec.

## Requirements

- macOS 14+, Apple Silicon
- Xcode 26+ (with the Metal Toolchain component, for MLX's GPU kernels)
- ~4 GB of model downloads on first launch (cached afterwards), ~4 GB RAM
  resident while running

## Build

Open `PushToTalk/PushToTalk.xcodeproj` and run, or:

```sh
cd PushToTalk
xcodebuild -scheme PushToTalk -configuration Release build
```

App Sandbox is intentionally off — sandboxed apps can't create event taps or
post synthetic keystrokes. Signed for personal use; not App Store material.

## Permissions

Grant on first run (System Settings → Privacy & Security):

| Permission       | Why                                  |
|------------------|--------------------------------------|
| Microphone       | recording while the hotkey is held   |
| Input Monitoring | seeing the hotkey press system-wide  |
| Accessibility    | posting the synthetic Cmd+V to paste |

If the hotkey silently stops working after a rebuild, remove and re-add the
app under Input Monitoring — macOS invalidates the grant when the binary
changes.
