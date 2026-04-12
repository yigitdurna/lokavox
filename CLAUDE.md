# LokaVox

Local push-to-talk voice dictation for macOS using whisper.cpp. Everything runs locally.

## How It Works
1. Press **dictation key** (F5 row, keycode 176) — hold for push-to-talk, double-tap for toggle
2. Audio captured via sox → transcribed locally via whisper-cli → pasted into active app via Cmd+V
3. Media (Spotify, YouTube, etc.) auto-pauses during recording, resumes after
4. Menu bar shows state: outline mic (idle), filled mic (recording), mic+dots (transcribing)
5. Recordings < 0.7s are discarded; Whisper hallucinations ("thank you", etc.) are filtered

## Architecture

Single Python script (`lokavox.py`):
- **sox** — audio capture (subprocess → temp WAV at 16kHz/16bit/mono)
- **whisper-cli** — local transcription (large-v3-turbo, ~1.6GB model)
- **Quartz CGEventTap** — global key interception, suppresses dictation key from macOS
- **Quartz CGEventPost** — simulates Cmd+V paste (NOT osascript — blocked on macOS 16+)
- **AppKit NSStatusBar** — menu bar with template images (auto light/dark theme)
- **AppleScript** — targeted media pause/resume for Spotify and Music (won't launch Apple Music)

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
    Info.plist                              # LSUIElement=true (no dock icon)
    MacOS/LokaVox                           # Shell wrapper (NO exec)
    Resources/
      AppIcon.icns                          # Copied by install.sh
~/.local/share/lokavox/venv/                # Python venv
~/.local/share/lokavox/settings.json            # User preferences
~/.local/share/whisper/ggml-large-v3-turbo.bin  # Whisper model (~1.6GB)
~/Library/LaunchAgents/com.local.lokavox.plist  # Auto-start (created by Preferences toggle)
```

## Critical Rules

1. **No exec in shell wrapper** — `exec` replaces process identity, breaks macOS TCC. The shell must stay as parent so LokaVox.app's permissions extend to the Python child.
2. **No osascript for keystrokes** — macOS 16+ blocks it (error 1002). Use Quartz CGEventPost.
3. **Re-codesigning invalidates permissions** — user must re-grant Accessibility/Microphone after.

## Permissions (Privacy & Security)
- **Accessibility** → LokaVox.app (CGEventTap + CGEventPost)
- **Microphone** → LokaVox.app (sox audio capture)

## Auto-Start
Managed via LaunchAgent plist (`~/Library/LaunchAgents/com.local.lokavox.plist`), toggled in Preferences → "Launch at Login". Uses `open -a` to launch the .app — survives re-codesigning (unlike Login Items, which break when the app signature changes).

## Dependencies
- Homebrew: `whisper-cpp`, `sox`
- Python venv: `pyobjc-framework-Quartz`, `pyobjc-framework-Cocoa`

## Future Enhancements (not yet implemented)
- **Move to another Mac**: Run CLAUDE-CODE-PROMPT.md setup on new machine, copy .app bundle, grant permissions
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
