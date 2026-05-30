# LokaVox

Local push-to-talk voice dictation for macOS using whisper.cpp. Everything runs locally.

## How It Works
1. **Hold Control** (default) for push-to-talk, **Control+Escape** to toggle. Alternative hotkey: the dictation key (F5 row, keycode 176) — hold for push-to-talk, double-tap for toggle (selectable in Preferences). On recent macOS the dictation key also triggers the OS's own Dictation below the event tap, so **Control is the conflict-free default**.
2. Audio captured via sox → transcribed locally via whisper-cli → pasted into active app via Cmd+V
3. Media (Spotify, YouTube, etc.) auto-pauses during recording, resumes after
4. Menu bar shows state: outline mic (idle), filled mic (recording), mic+dots (transcribing)
5. Recordings < 0.7s are discarded; Whisper hallucinations ("thank you", etc.) are filtered

## Architecture

Single Python script (`lokavox.py`):
- **sox** — audio capture (subprocess → temp WAV at 16kHz/16bit/mono)
- **whisper-cli** — local transcription (large-v3-turbo, ~1.6GB model). Output is filtered by: a silence energy-gate (sox RMS), the `_HALLUCINATIONS` denylist, and a vocab-echo guard that drops output consisting only of `--prompt` vocab tokens
- **Quartz CGEventTap** — global key interception. Suppresses the dictation key from apps; note recent macOS still fires its own Dictation for that key below the session tap (Control mode avoids this)
- **Quartz CGEventPost** — simulates Cmd+V paste (NOT osascript — blocked on macOS 16+)
- **AVFoundation** — requests Microphone permission at launch so the prompt is attributed to LokaVox.app (the spawned sox subprocess alone won't trigger it on modern macOS)
- **AppKit NSStatusBar** — menu bar with template images (auto light/dark theme); transcribing state animates a breathing pulse
- **AppleScript / injected JS** — targeted media pause/resume for Spotify, Music, and browser video (Brave/Chrome/Safari); won't launch apps that aren't already running

## File Layout

```
lokavox.py                                  # Main script (source of truth)
install.sh                                  # Build LokaVox.app, create venv, codesign
resources/
  AppIcon.icns                              # App icon (B&W nostalgic microphone)
  mic_idle.png                              # Menu bar: outline mic (template)
  mic_recording.png                         # Menu bar: filled mic (template)
  mic_transcribing.png                      # Menu bar: mic + dots (template)
~/Applications/LokaVox.app/
  Contents/
    Info.plist                              # LSUIElement + NSMicrophoneUsageDescription + NSAppleEventsUsageDescription
    MacOS/LokaVox                           # Compiled native arm64 launcher (Mach-O; posix_spawns python, waits)
    Resources/
      AppIcon.icns                          # Copied by install.sh
~/.local/share/lokavox/venv/                # Python venv
~/.local/share/lokavox/settings.json            # User preferences
~/.local/share/whisper/ggml-large-v3-turbo.bin  # Whisper model (~1.6GB)
~/Library/LaunchAgents/com.local.lokavox.plist  # Auto-start (created by Preferences toggle)
```

## Critical Rules

1. **Main executable is a compiled native launcher, NOT a shell script** — (a) a script main-exec has no architecture, so on Apple Silicon LaunchServices runs it as x86_64 and demands Rosetta; a Mach-O built for the host arch only (`clang -arch $(uname -m)`) launches natively. (b) The launcher `posix_spawn`s python and **waits** — it must NOT `exec`/replace itself, so the .app's signed main-exec process stays alive as python's parent and TCC (Accessibility/Microphone) extends to the python→sox children.
2. **No osascript for keystrokes** — macOS 16+ blocks it (error 1002). Use Quartz CGEventPost.
3. **Re-codesigning invalidates permissions** — user must re-grant Accessibility/Microphone after. `tccutil reset Accessibility com.local.lokavox` / `... Microphone ...` forces a clean re-prompt.
4. **Microphone requires NSMicrophoneUsageDescription in Info.plist** — without it, modern macOS silently denies the mic (no prompt) and sox records silence. The app also calls AVFoundation `requestAccess` at launch so the prompt attributes to LokaVox.app, not sox.
5. **Never launch the app from a terminal (or via Claude)** — TCC attributes permissions to the *responsible process*; launching through a shell attributes Accessibility/Microphone to the terminal/Claude, not LokaVox.app. Always launch the built `.app` from Finder.

## Permissions (Privacy & Security)
- **Accessibility** → LokaVox.app (CGEventTap + CGEventPost)
- **Microphone** → LokaVox.app (sox audio capture)

## Auto-Start
Managed via LaunchAgent plist (`~/Library/LaunchAgents/com.local.lokavox.plist`), toggled in Preferences → "Launch at Login". Uses `open -a` to launch the .app — survives re-codesigning (unlike Login Items, which break when the app signature changes).

## Dependencies
- Homebrew: `whisper-cpp`, `sox`
- Python venv: `pyobjc-framework-Quartz`, `pyobjc-framework-Cocoa`, `pyobjc-framework-AVFoundation` (install via `pip install --only-binary=:all:` — source builds fail under newer clang)
- Build: `clang` (Xcode Command Line Tools) to compile the launcher

## Future Enhancements (not yet implemented)
- **Move to another Mac**: `git clone` + `./install.sh` on the new machine, then grant Accessibility + Microphone (see README). Rebuild the `.app` there — don't copy the bundle, it must be signed on that machine.
- **Different trigger key**: Change `KEYCODE_DICTATION` constant. Use key sniffer script to find any key's code:
  `~/.local/share/lokavox/venv/bin/python3 /tmp/key_sniffer.py`

## Troubleshooting
- **Two menu bar icons** = two instances → `pkill -f lokavox`
- **Event tap fails** = accessibility not granted or signature changed after re-codesign
- **No paste** = accessibility permission missing (needed for CGEventPost)
- **No audio** = microphone permission missing for LokaVox.app
- **"Thank you" on short press** = adjust `MIN_RECORDING_SECS` or extend `_HALLUCINATIONS` set
- **Dictation key triggers macOS** = app not running or event tap disabled; restart app
- **Dictation key opens Apple Music** = old bug, was caused by MRMediaRemoteSendCommand(PAUSE) launching Music as default handler when nothing was playing. Fixed by switching to targeted AppleScript.
- **Two instances at login** = both LaunchAgent AND Login Items were active. Now using LaunchAgent only (managed via Preferences toggle). Remove any stale Login Items entry from System Settings → General → Login Items.
- **Not launching at login after re-codesign** = Login Items break when app signature changes. Switch to LaunchAgent via Preferences → "Launch at Login" (this is now the default mechanism).
- **"You need to install Rosetta" on launch** = the main executable was a shell script (old build). Rebuild with `./install.sh` — it compiles a native arm64 launcher now.
- **App opens but pastes nothing / records silence** = Microphone not granted to LokaVox.app, or Info.plist missing `NSMicrophoneUsageDescription`. Rebuild + grant Microphone. The vocab-echo / silence guards stop garbage ("Claude Claude") from being pasted when audio is silent.
- **"Claude" or a terminal appears in Accessibility/Microphone instead of LokaVox** = the app was launched from a shell, so TCC attributed the permission to the responsible process. Quit it, launch LokaVox.app from Finder, remove the stray entry, re-grant.
- **F5 prompts "enable Dictation?" even with the app running** = recent macOS handles the dictation key below the session event tap, so in-app suppression isn't enough. Use Control mode (Preferences → Hotkey).
- **Mic prompt never appears (app exits / no menu bar)** = without Accessibility the event tap fails; the app now shows an alert linking to the Accessibility pane instead of exiting silently. Grant it and relaunch.
