# LokaVox

Local push-to-talk voice dictation for macOS. Hold a key, speak, release — your words appear in whatever app is focused. Everything runs locally via [whisper.cpp](https://github.com/ggerganov/whisper.cpp); no cloud, no API keys, no telemetry.

- **Hold Control** → push-to-talk (hold for ~250ms before speaking)
- **Control + `** (backtick) → toggle recording on/off
- **Pauses** Spotify / Apple Music / video in Brave, Chrome, Safari while you speak, resumes after
- **Menu bar** icon shows idle / recording / transcribing
- **Custom vocabulary** and find-and-replace corrections in Preferences
- **Writing styles**: Standard or Lowercase
- **Alternative hotkey**: switch to the dedicated dictation key (F5 row) in Preferences

Uses `whisper-large-v3-turbo` (~1.6GB) for transcription quality. Tested on Apple Silicon macOS.

### Why the 250ms hold delay?

Control is a shared modifier key — you also press it for things like Ctrl+A, Ctrl+C, terminal shortcuts. LokaVox only starts recording after Control has been held alone for ~250ms, so quick modifier combos don't trigger accidental recordings. Hold Control briefly before you start speaking.

If you'd rather have an instant-start hotkey with no modifier collisions, switch to **Dictation Key (F5 row)** mode in Preferences. That key is the dedicated mic key on modern Mac keyboards; LokaVox intercepts it so macOS's built-in dictation won't fire.

## Install

```bash
# 1. System dependencies
brew install whisper-cpp sox

# 2. Whisper model (~1.6GB, one-time)
mkdir -p ~/.local/share/whisper
curl -L -o ~/.local/share/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin

# 3. Clone and build the .app bundle
git clone https://github.com/yigitdurna/lokavox.git
cd lokavox
./install.sh
```

`install.sh` creates a Python venv, builds `~/Applications/LokaVox.app`, and codesigns it.

## First run

Launch `LokaVox.app` from `~/Applications/`. On first run, macOS will prompt for two permissions:

- **Accessibility** → required to capture the hotkey and paste into the focused app (`System Settings → Privacy & Security → Accessibility`)
- **Microphone** → required for audio capture (`System Settings → Privacy & Security → Microphone`)

Grant both and restart the app. The menu bar mic icon should appear.

To launch at login: `System Settings → General → Login Items → add LokaVox.app`.

### Browser video pause (optional)

For LokaVox to pause videos in Chrome/Brave/Safari, enable "Allow JavaScript from Apple Events" in each browser's Develop menu. Spotify and Apple Music work without any extra setup.

## Preferences

Click the menu bar mic → Preferences. You can set:

- **Hotkey** — `Control` (default) or `Dictation Key (F5 row)`
- **Writing style** — `Standard` (proper caps + punctuation) or `Lowercase`
- **Vocabulary** — one word or phrase per line, passed to whisper as a prompt so it recognizes domain terms like product names or jargon
- **Corrections** — one per line, format `wrong >> right`, applied as word-boundary regex after transcription

Click **Save** to commit and see a `✓ Saved` confirmation; closing the window also saves automatically. Settings persist in `~/.local/share/lokavox/settings.json`.

## How it works

Single Python script (`lokavox.py`):

- **sox** captures audio to a temp WAV (16 kHz, mono, 16-bit)
- **whisper-cli** transcribes locally using `ggml-large-v3-turbo.bin`
- **Quartz CGEventTap** intercepts keyboard events globally. In Control mode it listens for `flagsChanged` events on the Control key and passes them through (Control remains usable for other shortcuts). In Dictation-key mode it fully suppresses the mic key so macOS's built-in dictation won't fire.
- **Quartz CGEventPost** simulates Cmd+V to paste (osascript keystroke is blocked on macOS 16+)
- **AppKit NSStatusBar** drives the menu bar UI with template images for auto light/dark
- **AppleScript** targets Spotify, Music, Brave, Chrome, Safari for pause/resume — won't launch apps that aren't already running

Recordings shorter than 0.7s are discarded. Common whisper hallucinations on silence (`"thank you"`, `"subscribe"`, etc.) are filtered out.

## Uninstall

```bash
# Remove the app and data
rm -rf ~/Applications/LokaVox.app
rm -rf ~/.local/share/lokavox
rm -rf ~/.local/share/whisper   # only if nothing else uses whisper

# Optional: remove Homebrew packages if unused elsewhere
brew uninstall whisper-cpp sox
```

Then in `System Settings`:
- General → Login Items → remove LokaVox
- Privacy & Security → Accessibility → remove LokaVox.app
- Privacy & Security → Microphone → remove LokaVox.app

LokaVox does not modify `~/.zshrc`, macOS dictation settings, or any system defaults.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Two menu bar icons | Two instances running — `pkill -f lokavox` |
| Event tap fails on startup | Accessibility not granted, or re-codesigning invalidated permission — re-grant |
| No paste after speaking | Accessibility permission missing |
| No audio captured | Microphone permission missing |
| Transcribes `"thank you"` on short press | Too-short recording — hold longer, or tweak `MIN_RECORDING_SECS` |
| Nothing happens when I hold Control | Hold for ~250ms before speaking — shorter presses are treated as modifier combos and ignored |
| Control+` (backtick) doesn't toggle | Another app is consuming the shortcut first; check System Settings → Keyboard → Shortcuts for conflicts |
| F5 still triggers macOS dictation | Only relevant in Dictation-key mode. LokaVox not running or event tap disabled — restart the app |

## License

[MIT](LICENSE)
