# LokaVox

Local push-to-talk voice dictation for macOS. Hold a key, speak, release — your words appear in whatever app is focused. Everything runs locally via [whisper.cpp](https://github.com/ggerganov/whisper.cpp); no cloud, no API keys, no telemetry.

- **Hold Control** → push-to-talk (hold for ~250ms before speaking)
- **Control + Escape** → toggle recording on/off
- **Pauses** Spotify / Apple Music / video in Brave, Chrome, Safari while you speak, resumes after
- **Menu bar** icon shows idle / recording / transcribing
- **Custom vocabulary** and find-and-replace corrections in Preferences
- **Writing styles**: Standard or Lowercase
- **Alternative hotkey**: switch to the dedicated dictation key (F5 row) in Preferences

Uses `whisper-large-v3-turbo` (~1.6GB) for transcription quality. Tested on Apple Silicon macOS.

### Why the 250ms hold delay?

Control is a shared modifier key — you also press it for things like Ctrl+A, Ctrl+C, terminal shortcuts. LokaVox only starts recording after Control has been held alone for ~250ms, so quick modifier combos don't trigger accidental recordings. Hold Control briefly before you start speaking.

There's also a **Dictation Key (F5 row)** mode in Preferences (the dedicated mic key). Note: on recent macOS that key also triggers the OS's *own* Dictation at a level the app can't fully suppress, so you may see an "enable Dictation?" prompt. **Control mode is recommended** unless you've disabled macOS Dictation for that key.

## Requirements

- **Apple Silicon Mac** (Intel works too — the launcher is built for your architecture)
- **macOS 13 (Ventura) or later**
- **[Homebrew](https://brew.sh)**
- **Xcode Command Line Tools** — `xcode-select --install` (provides `clang` and `python3`)

## Install

```bash
git clone https://github.com/yigitdurna/lokavox.git
cd lokavox
./install.sh
```

`install.sh` is a one-shot: it installs the Homebrew dependencies (`whisper-cpp`, `sox`) if missing, creates a Python venv, downloads the Whisper model (~1.6 GB, one-time), builds a native `~/Applications/LokaVox.app`, and ad-hoc codesigns it.

## First run

Launch **LokaVox.app from Finder** (in `~/Applications/`). Do **not** launch it from a terminal — macOS would attribute the permissions to the terminal instead of to LokaVox.

You'll be asked for two permissions:

- **Microphone** → a prompt appears automatically on first launch; click **Allow**. (`System Settings → Privacy & Security → Microphone`)
- **Accessibility** → required to capture the hotkey and paste. If it isn't granted yet, LokaVox shows an alert with a button straight to the right Settings pane — enable **LokaVox** there.

Grant both, then **relaunch from Finder**. A mic icon in the menu bar means it's running.

**Launch at login:** enable it in **LokaVox → Preferences → "Launch at Login"** (installs a LaunchAgent). Don't use System Settings → Login Items — that entry breaks whenever the app is re-signed.

### Browser video pause (optional)

For LokaVox to pause videos in Chrome/Brave/Safari, enable "Allow JavaScript from Apple Events" in each browser's Develop menu. Spotify and Apple Music work without any extra setup.

## Preferences

Click the menu bar mic → Preferences. You can set:

- **Hotkey** — `Control` (default) or `Dictation Key (F5 row)`
- **Writing style** — `Standard` (proper caps + punctuation) or `Lowercase`
- **Vocabulary** — token field for words and phrases passed to Whisper as a prompt so it recognizes domain terms like product names or jargon. Type a word and press Enter or comma to add it as a pill; select a pill and press Backspace to remove.
- **Corrections** — a scrollable list of find-and-replace rules applied after transcription. Click **+ Add correction** to create a new row, fill in the two fields, and click the **×** to delete a row. Matches are word-boundary and case-insensitive.

Click **Save** to commit and see a `✓ Saved` confirmation; closing the window also saves automatically. Settings persist in `~/.local/share/lokavox/settings.json`.

## How it works

Single Python script (`lokavox.py`):

- **sox** captures audio to a temp WAV (16 kHz, mono, 16-bit)
- **whisper-cli** transcribes locally using `ggml-large-v3-turbo.bin`
- **Quartz CGEventTap** intercepts keyboard events globally. In Control mode it listens for `flagsChanged` events on the Control key and passes them through (Control remains usable for other shortcuts). In Dictation-key mode it suppresses the mic key — though on recent macOS the OS still fires its own Dictation for that key below the session tap, which is why **Control is the recommended default**.
- **Quartz CGEventPost** simulates Cmd+V to paste (osascript keystroke is blocked on macOS 16+)
- **AppKit NSStatusBar** drives the menu bar UI with template images for auto light/dark
- **AppleScript** targets Spotify, Music, Brave, Chrome, Safari for pause/resume — won't launch apps that aren't already running

Output is filtered on several fronts so nothing garbage gets pasted: recordings shorter than 0.7s are discarded, near-silent captures are dropped by an audio energy gate (so a missing mic permission can't produce text), common whisper hallucinations on silence (`"thank you"`, `"subscribe"`, etc.) are denylisted, and any output consisting only of your vocabulary/prompt words is treated as a prompt-echo and dropped.

## Uninstall

```bash
# Remove the app and data
rm -rf ~/Applications/LokaVox.app
rm -rf ~/.local/share/lokavox
rm -rf ~/.local/share/whisper   # only if nothing else uses whisper

# Remove the launch-at-login agent (if you enabled it)
rm -f ~/Library/LaunchAgents/com.local.lokavox.plist

# Optional: remove Homebrew packages if unused elsewhere
brew uninstall whisper-cpp sox
```

Then in `System Settings → Privacy & Security`:
- Accessibility → remove LokaVox.app
- Microphone → remove LokaVox.app

LokaVox does not modify `~/.zshrc`, macOS dictation settings, or any system defaults.

## Troubleshooting

| Symptom | Fix |
|---|---|
| **"You need to install Rosetta"** on launch | Old build with a shell-script launcher. Rebuild with `./install.sh` — it now compiles a native launcher for your architecture. |
| **App opens then vanishes** (no menu bar icon) | Accessibility not granted. LokaVox shows an alert with a button to the right pane — enable it there and relaunch from Finder. |
| **Records nothing / pastes nothing**, or pastes a repeated vocabulary word | Microphone not granted to LokaVox.app, so `sox` records silence. Grant Microphone, then relaunch from Finder. (The silence + prompt-echo guards stop garbage being pasted in the meantime.) |
| **"Claude" or a terminal** appears in Accessibility/Microphone instead of LokaVox | The app was launched from a terminal, so macOS attributed the permission to that process. Quit it, launch LokaVox.app from Finder, remove the stray entry, and re-grant. |
| Two menu bar icons | Two instances running — `pkill -f lokavox` |
| No paste after speaking | Accessibility permission missing — re-grant |
| Transcribes `"thank you"` on a short press | Too-short / near-silent recording — hold longer, or tweak `MIN_RECORDING_SECS` |
| Nothing happens when I hold Control | Hold for ~250ms before speaking — shorter presses are treated as modifier combos and ignored |
| Control+Escape doesn't toggle | Another app is consuming the shortcut first; check System Settings → Keyboard → Shortcuts for conflicts |
| F5 prompts "enable Dictation?" | Recent macOS handles the dictation key below the event tap — use Control mode, or disable macOS Dictation for that key |

## License

[MIT](LICENSE)
