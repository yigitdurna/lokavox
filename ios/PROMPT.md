# LokaVox iOS — Kickoff Prompt

Paste this into a fresh Claude Code session started in `~/dev/projects/lokavox/ios/`.

---

We are starting a new project: an iOS port of the LokaVox Mac app. The Mac version is a local push-to-talk voice dictation tool. The iOS version is a custom keyboard extension that does the same thing via the globe key.

**Before doing anything, read these files fully and do not skim:**

1. `CLAUDE.md` in this directory — the full project context, architecture decisions, and critical rules
2. `../CLAUDE.md` — the Mac LokaVox docs, for feature parity reference
3. `../lokavox.py` — the Mac implementation, so you understand what behaviors we're porting
4. `reference/README.md` — the TypeWhisper-iOS README, for a sense of the reference codebase

**Then read these specific reference files, because they encode solutions to problems we will also face:**

5. `reference/project.yml` — xcodegen config, entitlements, target structure
6. `reference/TypeWhisperKeyboard/TypeWhisperKeyboard.entitlements` and the other three `.entitlements` files
7. `reference/TypeWhisperKeyboard/Resources/Info.plist` and `reference/TypeWhisper/Resources/Info.plist`
8. `reference/TypeWhisperKeyboard/KeyboardViewController.swift` if it exists at that path (find it — it's the `NSExtensionPrincipalClass` entry point)
9. `reference/TypeWhisper/Services/FlowSessionManager.swift` — the Flow mode background-mic pattern
10. `reference/TypeWhisper/Services/ModelManagerService.swift` and `AudioRecordingService.swift`
11. `reference/Shared/` — all files, this is the App Group IPC layer

**After reading, do not start coding yet.** Instead, produce a plan that covers:

### Plan deliverables

**A. Project skeleton.** A `project.yml` for `src/` that defines the three targets (main app, keyboard extension, and — only if needed — a shared framework), their entitlements, bundle IDs (`com.lokavox.app`, `com.lokavox.app.keyboard`), App Group (`group.com.lokavox.shared`), Info.plists, and SwiftPM dependency on WhisperKit. Show me the file before generating. Do not include widget or share extensions — we are not building those in V1.

**B. Build order.** A sequenced plan of what gets built first, second, third. My suggestion as starting point, challenge it if you disagree:
   1. Project skeleton builds and runs empty on device (verify entitlements, team, signing all work)
   2. Main app only: model download UI, load WhisperKit, record audio via button in the app itself, transcribe, display result. No keyboard yet.
   3. Keyboard extension: simplest possible "tap mic → record → transcribe → insert text" path, with the app-switch tax on every dictation (no Flow mode yet). Model lives in main app, keyboard triggers main app via URL scheme + App Group.
   4. Flow mode: keep the mic session alive for ~5 minutes after last utterance, so subsequent dictations don't re-trigger the main app.
   5. Vocabulary + corrections (port from Mac).

**C. Flow mode design.** Before building step 4, write a design doc describing exactly how Flow mode works — what stays alive in which process, how the keyboard signals "I'm still here, keep the mic open," how the session ends, what happens when iOS suspends the main app mid-session, how we recover. Ground this in what `FlowSessionManager.swift` in the reference does. Call out the differences between their approach and ours if any.

**D. Known risks.** Flag the three or four things most likely to bite us, in priority order, with a sentence on how we'd know they're happening and what we'd do about it. Cold-start latency and keyboard-to-app wake-up reliability are probably two of them — TypeWhisper has documented issues with the latter on iOS 26.4+.

**E. What you want me to verify/do before you start coding.** I (Yigit) have Xcode installed and a paid Apple Developer account. I've worked on other iOS apps but haven't shipped to App Store or TestFlight. If you need me to create anything in the Apple Developer portal (App ID, App Group identifier, provisioning profiles) before you generate the project, tell me now, not halfway through.

### Non-negotiables

- No network calls anywhere in our code. None. WhisperKit handles the one-time model download internally; that's the only network activity in the system.
- Keyboard extension stays under 70 MB. Model loads in main app only.
- App Group ID must be `group.com.lokavox.shared` exactly.
- Write our own code from scratch. Reference is for reading patterns, not copying code. TypeWhisper is GPLv3, LokaVox is MIT.
- Flow mode ships in V1. It's the whole reason we're building this rather than using Apple's built-in dictation.

### Working style

- Start in plan mode. I want to see the plan before any file gets created.
- Simplicity first. Don't over-engineer. When TypeWhisper does something elaborate, ask whether we actually need it.
- Be honest about uncertainty. If you're not sure a particular API behaves the way you think it does, say so and verify.
- Ask me before changing the project structure, before adding dependencies, and before making any decision that would affect App Store review (relevant later, but still).

Once you've read the files and produced the plan, we'll review it together and then proceed to build step 1.
