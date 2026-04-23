# Reply to Claude Code — after initial plan

Paste this as your response to the plan it produced.

---

Plan looks good. Better than what my ChatGPT session had. Approving, with answers to your questions below and one addition.

## Addition: sub-agent usage

I've added three sub-agents under `.claude/agents/`:

- **reference-reader** — for reading TypeWhisper files under `reference/`. Use this every time you need to understand a TypeWhisper pattern instead of reading files into your own context. Your job is to stay the architect; sub-agent summarizes.
- **swift-implementer** — for writing individual Swift files from a spec you hand it. Use this for any file larger than ~50 lines or any time you want to keep your context clean. You provide the spec, it writes the file, you review.
- **ios-researcher** — for specific questions about iOS / Swift / Apple APIs / WhisperKit. Use this instead of guessing. E.g. "is the iOS 26.4+ app-switch-back issue fixed in 26.5?" — send that to ios-researcher.

**Rule of thumb:** if a task would require you to read >500 lines from any source (reference code, Apple docs, Swift API docs), delegate to the appropriate sub-agent. Keep your own context focused on architecture, cross-file coordination, and talking to me.

## Answers to your six questions

1. **Apple Developer Team ID:** I do not have a paid Apple Developer account. Free Apple ID only. My Team ID will be the personal-team one Xcode auto-generates when I sign in. I'll get it to you once the project.yml is ready to populate — easiest way is Xcode will show it when I open the project and select signing. Plan for this: free-account constraints mean 7-day re-sign, but everything else works (App Groups, keyboard extensions, URL schemes all fine on free accounts).

2. **App Group pre-registration:** I'll do this before first build. Free-account flow is different from paid — free accounts cannot access the developer portal at all, so App Group registration has to happen through Xcode's "Signing & Capabilities" editor rather than via the portal. If you hit issues at build step, flag it and I'll sort the Xcode side.

3. **Model:** `openai_whisper-large-v3-turbo`, default, no smaller fallback in V1. Matches Mac, ship one thing well. Agreed.

4. **Test device:** iPhone 16 Pro, iOS 18.x (confirm current version at test time).

5. **Xcode:** Xcode 16+, installed. iOS 18+ on device.

6. **URL scheme:** `lokavox` is fine. If collision comes up later we rename.

## One thing to flag

Before we commit to Flow mode exactly as you've designed it (fixed 300s window, no extension on activity), do a quick **ios-researcher** query: "On iOS 18+, does AVAudioEngine running with UIBackgroundModes=audio get killed if the main app has been backgrounded but the user hasn't interacted with it in several minutes, despite the engine actively processing audio?" I want to make sure the 5-minute window is actually survivable on current iOS before we build around it. If iOS suspends us at 3 minutes regardless, our window needs to be shorter or we need a different strategy.

## Go ahead with step 1

Generate `src/project.yml`, both Info.plists, both entitlements files, and empty-shell Swift files for the two targets. Do not include any functional code yet — just enough that `xcodegen generate` + opening in Xcode + selecting my free Apple ID team + building = a working empty app and empty keyboard on my phone. I'll do the App Group registration and team selection in Xcode after you generate.

Use the swift-implementer sub-agent to write the shell Swift files. You handle the project.yml and plist files directly since those are small and you need to stay across them.

When step 1 is done and verified on device, we move to step 2.
