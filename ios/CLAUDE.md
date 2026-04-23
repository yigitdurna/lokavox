# LokaVox iOS

Local speech-to-text keyboard for iPhone, continuation of the LokaVox Mac app. Native Swift/SwiftUI. All transcription runs on-device via WhisperKit with Whisper large-v3-turbo.

## Sub-Agent Usage (Important)

This project uses three sub-agents defined in `.claude/agents/`:

- **reference-reader** — reads and summarizes files under `reference/` (TypeWhisper source). Use instead of reading TypeWhisper files directly. Protects your context AND prevents accidental GPL-code shape-copying.
- **swift-implementer** — writes Swift files given a spec. Use for any file >50 lines or any implementation where you want to stay focused on architecture.
- **ios-researcher** — answers specific iOS/Swift/Apple API/WhisperKit questions via web search of authoritative sources. Use instead of guessing.

**Default posture:** the main agent (you) is the architect and coordinator. Delegate reading, writing, and researching to sub-agents wherever it keeps your context clean. The main agent holds the plan and the cross-file mental model; sub-agents do the focused work.

**Session-start note:** sub-agents are loaded when Claude Code starts. If you added new ones or edited existing ones, restart Claude Code to pick them up. If a fresh restart still doesn't surface them as invokable agent types, check:
1. File placement: `.claude/agents/*.md` in the project root (here) or `~/.claude/agents/*.md` user-globally. Both should work.
2. YAML frontmatter validity: `name`, `description`, `tools` fields; closing `---` on its own line.
3. `tools` field values must match your Claude Code version's expected tool names (`Read`, `Grep`, `Glob`, `Write`, `Edit`, `Bash`, `WebSearch`, `WebFetch`). Unknown tool names may fail the parse silently.

If sub-agents are genuinely unavailable in the current session, fall back to `general-purpose` with the equivalent prompt constraints (e.g. paste the relevant `.md` body into the task prompt), and flag it so it can be fixed for future sessions.

## Relationship to Mac App

This is a sibling product to `../lokavox.py`, sharing the LokaVox name, privacy stance (100% local, no cloud, no telemetry), and the underlying Whisper model (`ggml-large-v3-turbo`). Behaviors differ because iOS is not macOS — no global hotkeys, no paste-into-any-app via Cmd+V, no AppleScript. The iOS surface is a custom keyboard extension instead.

## Architecture Overview

Three targets:

1. **LokaVox app** (main) — holds WhisperKit model in memory, manages audio recording in background, writes transcribed text to App Group shared container. Has `UIBackgroundModes: audio` to keep the mic alive in Flow mode.
2. **LokaVoxKeyboard extension** — thin UI surface. Captures audio or triggers main app to capture, reads transcribed text from App Group, inserts into active text field via `textDocumentProxy.insertText()`. Memory budget ~70 MB — model CANNOT load here.
3. **App Group shared container** (`group.com.lokavox.shared`) — UserDefaults + JSON files for IPC between main app and keyboard.

The critical pattern is: **keyboard wakes main app → main app does the heavy lifting → result flows back to keyboard via App Group**. See `reference/TypeWhisper/Services/FlowSessionManager.swift` for the proven pattern (read via reference-reader sub-agent, not directly).

## Flow Mode (Primary UX Goal)

Once a dictation session starts, the mic stays open for ~5 minutes after the last utterance, so the user can keep talking without bouncing back to the main app every time. This is the whole point of Flow mode and it is what makes the keyboard actually usable as a daily driver. Without it, every single dictation costs an app-switch, which is the failure mode that makes Superwhisper's iOS keyboard feel mediocre.

Implementation reference: `reference/TypeWhisper/Services/FlowSessionManager.swift` — query via reference-reader sub-agent before designing Flow mode.

**Research finding from step 1 (iOS 18+):** a 5-min Flow window survives on iOS 18/26 as long as the AVAudioEngine input tap is continuously processing buffers and the audio session is active — Apple's "Enabling Background Audio" doc confirms the app stays alive while recording audio content. Two caveats must be handled during Flow mode implementation (step 4):

1. **Interruption handling is non-optional.** Phone calls, Siri, CallKit, FaceTime, another app grabbing exclusive audio — any of these pauses AVAudioEngine. Without an `AVAudioSession.interruptionNotification` handler and explicit resume logic, the Flow session silently dies mid-window. Build this when building Flow mode, not as a polish pass later.
2. **Jetsam (memory-pressure kill) still applies.** Background-audio mode does NOT exempt the main app from device-wide memory reclaim. Keep the main app lean: model resident, nothing else large. If the main app gets Jetsammed, the heartbeat goes stale and the keyboard detects it — but in-flight audio is lost.

## Feature Parity with Mac LokaVox

**V1 must have:**
- Tap mic → record → release → transcribe → insert (the basic path)
- Whisper large-v3-turbo model (same file as Mac: `ggml-large-v3-turbo.bin`, downloaded once in-app)
- Flow mode (as described above) — non-negotiable

**V1.1 (soon after):**
- Custom vocabulary (Whisper initial_prompt parameter, same behavior as Mac)
- Find-and-replace corrections (word-boundary, case-insensitive, post-transcription)

**V2 (if it makes sense):**
- Alternative trigger patterns
- Writing style (Standard vs Lowercase) — probably trivial to port from Mac

**What explicitly does NOT port:**
- Global hotkey interception (doesn't exist on iOS)
- Media pause/resume via AppleScript (no AppleScript on iOS — AVAudioSession ducking is possible but not app-targeted, probably not worth it)
- Menu bar UI (no menu bar)
- Login Items / LaunchAgent (doesn't apply)

## Reference Material

`reference/` contains a clone of the TypeWhisper-iOS repo (GPLv3). Do NOT copy their code directly — this is a from-scratch build informed by their patterns. Always access reference material via the reference-reader sub-agent.

Files most worth querying about:

- `reference/TypeWhisperKeyboard/KeyboardViewController.swift` — UIInputViewController setup and keyboard UI wiring
- `reference/TypeWhisper/Services/FlowSessionManager.swift` — background-mic pattern
- `reference/TypeWhisper/Services/ModelManagerService.swift` — WhisperKit model download and dispatch
- `reference/TypeWhisper/Services/ProfileService.swift` — profile sync across app/keyboard via App Group
- `reference/Shared/` — App Group IPC layer
- `reference/project.yml` — xcodegen config, shows entitlements and target structure

**Licensing discipline:** TypeWhisper is GPLv3. LokaVox is MIT. Write LokaVox code from scratch using TypeWhisper's patterns as reference. Do not paste their code. When the reference-reader returns a summary of a TypeWhisper pattern, describe the pattern to the swift-implementer in your own words; do not pass TypeWhisper source through. If a construct is genuinely Apple-API-idiomatic (the only reasonable way to write it), that's fine — idioms aren't copyrightable. But structural copying is out.

## Critical Rules

1. **No network calls, ever.** LokaVox's whole value is local transcription. Any URLSession, URLRequest, or HTTP URL in the code is a bug. Same discipline as the Mac version. The only exception is the one-time Whisper model download from HuggingFace, and that happens inside WhisperKit, not in LokaVox code.
2. **Keyboard stays under memory limit.** ~70 MB hard cap. Model lives in main app only. When in doubt, move work to the main app.
3. **Full Access is required** for microphone access from the keyboard. Document this clearly in onboarding. Use the `UIPasteboard.general.hasStrings` check pattern to work around `hasFullAccess` staleness — reference-reader can find the exact pattern.
4. **App Group ID is `group.com.lokavox.shared`** — all targets must have this entitlement.
5. **Flow mode is non-negotiable for V1.** Without it, the UX is worse than Apple's built-in dictation and the whole project is pointless.
6. **Handle audio interruptions explicitly.** Any code that starts an AVAudioSession / AVAudioEngine must register for `AVAudioSession.interruptionNotification` and implement resume. Silent session death from a phone call is not an acceptable failure mode.

## Apple Developer Account Status

Yigit has a **free Apple ID only** — no paid Apple Developer Program membership. Constraints:

- Personal-team signing only; Team ID comes from Xcode auto-generating a personal team on first sign-in
- 7-day app re-sign cycle (builds must be refreshed weekly on device)
- **App Groups with free accounts must be registered via Xcode's Signing & Capabilities editor**, not the developer portal (free accounts can't access the portal at all). When adding the App Group capability in Xcode, the group identifier `group.com.lokavox.shared` will be registered automatically against the personal team on first build. If a build fails with a missing-entitlement error, check this.
- Ad-hoc distribution to friends via AltStore / Sideloadly is possible, also 7-day re-sign per person
- No TestFlight, no App Store — not planned

This is fine for personal use. If Yigit later wants to ship publicly, that's a $99/year upgrade and a separate conversation.

## Project Structure

```
lokavox/ios/
├── CLAUDE.md                    # this file
├── PROMPT.md                    # kickoff prompt (historical)
├── REPLY.md                     # reply to first Claude Code plan (historical)
├── README.md                    # to be written during build
├── .claude/
│   └── agents/                  # sub-agent definitions
│       ├── reference-reader.md
│       ├── swift-implementer.md
│       └── ios-researcher.md
├── reference/                   # TypeWhisper clone (read-only, access via reference-reader)
└── src/
    ├── project.yml              # xcodegen config (generated .xcodeproj is gitignored)
    ├── Shared/
    │   └── LokaVoxConstants.swift    # App Group ID and other shared constants
    ├── LokaVox/                 # main app
    │   ├── App/
    │   │   └── LokaVoxApp.swift
    │   ├── Views/
    │   │   └── ContentView.swift
    │   ├── Models/              # (populated as services are added)
    │   ├── Services/            # (populated as services are added:
    │   │                        #    FlowSessionManager, ModelManagerService,
    │   │                        #    AudioRecordingService, WhisperEngine)
    │   └── Resources/
    │       ├── Info.plist
    │       └── LokaVox.entitlements
    └── LokaVoxKeyboard/         # keyboard extension
        ├── KeyboardViewController.swift
        └── Resources/
            ├── Info.plist
            └── LokaVoxKeyboard.entitlements
```

## Development Setup

- iOS 18.0+ deployment target
- Swift 6, strict concurrency
- Xcode 16+ (installed)
- xcodegen for project generation (install: `brew install xcodegen`)
- Test device: iPhone 16 Pro
- Dependencies via SwiftPM: WhisperKit (argmaxinc/WhisperKit), nothing else unless justified

## Build & Run

From `ios/src/`:

```
xcodegen generate             # regenerate LokaVox.xcodeproj after any project.yml change
open LokaVox.xcodeproj        # open in Xcode
```

In Xcode on first open:
1. Select both targets (LokaVox, LokaVoxKeyboard) → Signing & Capabilities.
2. Tick "Automatically manage signing" and set Team to your personal (free) Apple ID team.
3. On both targets: + Capability → App Groups → add `group.com.lokavox.shared`.
4. Plug in iPhone 16 Pro, select it as run destination, ⌘R.
5. On device: trust dev cert (Settings → General → VPN & Device Management) if prompted.
6. Add the keyboard: Settings → General → Keyboard → Keyboards → Add New Keyboard → LokaVox → tap LokaVox → Allow Full Access.

## Progress Log

### Step 1 — Skeleton (DONE)
Empty app + empty keyboard running on device. Verified by: main app launches without crash, keyboard appears in keyboard switcher, Full Access accepts-on, keyboard placeholder renders in Notes/Messages. No functional code yet.

### Step 2 — In-app transcription (next)
Main app only: WhisperKit model download UI, record button, transcribe, display result. No keyboard involvement. Measure cold-start latency.

### Step 3 — Keyboard v0 (bounce-to-app)
Simplest keyboard → main app → back path via URL scheme + App Group. Known rough UX; proves the IPC wiring.

### Step 4 — Flow mode
Long-lived AVAudioEngine in main app, keyboard flips state flags. Includes interruption handling (see Critical Rules #6) from the start.

### Step 5 — Vocabulary + corrections
Port from Mac LokaVox.

## Testing Approach

Physical device required for:
- Microphone (simulator can't record real audio)
- Keyboard extension Full Access behavior
- Memory pressure testing (simulator doesn't enforce the 70 MB limit)

Simulator is fine for:
- UI layout iteration
- Model download flow
- Non-keyboard parts of the main app

## Known Hard Problems

1. **Keyboard → main app wake-up.** TypeWhisper handles this via URL scheme + App Group. iOS 26.4+ reportedly requires manual user input to switch back to the calling app — TypeWhisper is still working on this. We'll inherit the same constraint. Verify current state via ios-researcher before Flow mode implementation.
2. **Cold-start latency.** First transcription after main app was killed by iOS = model load from disk. 3–8 seconds expected (verify in step 2). Flow mode masks this by keeping the session warm.
3. **Audio interruptions kill the session.** Calls, Siri, FaceTime, etc. pause AVAudioEngine. Must handle `AVAudioSession.interruptionNotification` and resume. Non-optional for Flow mode.
4. **Main app can still be Jetsammed.** Background audio mode does not exempt us from memory-pressure kills. Keep the main app lean; detect stale heartbeat in keyboard and wake main app again.
