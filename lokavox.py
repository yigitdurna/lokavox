#!/usr/bin/env python3
"""
lokavox.py — Local push-to-talk dictation using whisper.cpp

Hold dictation key (F5) to record, release to transcribe and paste.
Double-tap to toggle: recording continues, tap again to stop.
Pauses/resumes media playback automatically during recording.

Menu bar: outline mic (idle), filled mic (recording), mic+dots (transcribing).
Everything runs locally. No cloud, no API keys.

Dependencies:
    brew install whisper-cpp sox
    pip3 install pyobjc-framework-Quartz pyobjc-framework-Cocoa

Model:
    ~/.local/share/whisper/ggml-large-v3-turbo.bin
"""

import subprocess
import sys
import os
import re
import json
import tempfile
import threading
import signal
import argparse
import time
from pathlib import Path

try:
    import objc
    import Quartz
    from Foundation import NSObject
    from AppKit import (
        NSApplication,
        NSImage,
        NSStatusBar,
        NSVariableStatusItemLength,
        NSMenu,
        NSMenuItem,
        NSApplicationActivationPolicyAccessory,
        NSWindow,
        NSTextField,
        NSTextView,
        NSScrollView,
        NSColor,
        NSFont,
        NSPopUpButton,
        NSApp,
    )
    from PyObjCTools import AppHelper
except ImportError:
    print("Missing PyObjC. Install:")
    print("  pip3 install pyobjc-framework-Quartz pyobjc-framework-Cocoa")
    sys.exit(1)

# --- Config ---
MODEL = Path.home() / ".local/share/whisper" / "ggml-large-v3-turbo.bin"
SAMPLE_RATE = 16000
SETTINGS_DIR = Path.home() / ".local/share/lokavox"
SETTINGS_FILE = SETTINGS_DIR / "settings.json"

_DEFAULT_VOCAB = []
_DEFAULT_FIXUPS = []

# macOS key codes
KEYCODE_DICTATION = 176
DOUBLE_TAP_WINDOW = 0.35  # seconds
MIN_RECORDING_SECS = 0.7  # ignore accidental taps

# Whisper hallucinates these on silence/short audio
_HALLUCINATIONS = {
    "thank you", "thanks for watching", "thanks for listening",
    "subscribe", "like and subscribe", "bye", "you",
    "the end", "thanks", "thank you for watching",
}

# Media pause/resume via AppleScript (targeted per-app, won't launch Apple Music)
# Browsers need "Allow JavaScript from Apple Events" enabled in Developer menu
_JS_PAUSE = "(() => { for (const v of document.querySelectorAll('video')) { if (!v.paused) { v.pause(); v.dataset.whisperPaused = '1'; return 'paused'; } } for (const a of document.querySelectorAll('audio')) { if (!a.paused) { a.pause(); a.dataset.whisperPaused = '1'; return 'paused'; } } return 'none'; })()"
_JS_RESUME = "(() => { for (const el of document.querySelectorAll('[data-whisper-paused]')) { delete el.dataset.whisperPaused; el.play(); } })()"

_PAUSE_SCRIPT = f'''
if application "Spotify" is running then
    tell application "Spotify"
        if player state is playing then
            pause
            return "Spotify"
        end if
    end tell
end if
if application "Music" is running then
    tell application "Music"
        if player state is playing then
            pause
            return "Music"
        end if
    end tell
end if
if application "Brave Browser" is running then
    tell application "Brave Browser"
        repeat with w in windows
            repeat with t in tabs of w
                try
                    set r to execute t javascript "{_JS_PAUSE}"
                    if r is "paused" then return "Brave Browser"
                end try
            end repeat
        end repeat
    end tell
end if
if application "Google Chrome" is running then
    tell application "Google Chrome"
        repeat with w in windows
            repeat with t in tabs of w
                try
                    set r to execute t javascript "{_JS_PAUSE}"
                    if r is "paused" then return "Google Chrome"
                end try
            end repeat
        end repeat
    end tell
end if
if application "Safari" is running then
    tell application "Safari"
        repeat with w in windows
            repeat with t in tabs of w
                try
                    set r to do JavaScript "{_JS_PAUSE}" in t
                    if r is "paused" then return "Safari"
                end try
            end repeat
        end repeat
    end tell
end if
return "none"
'''

_CHROMIUM_BROWSERS = {"Brave Browser", "Google Chrome"}
_NATIVE_APPS = {"Spotify", "Music"}


# --- Settings ---

class Settings:
    """Persistent settings backed by JSON file."""

    STYLES = ["Standard", "Lowercase"]

    def __init__(self):
        self.vocab = list(_DEFAULT_VOCAB)
        self.fixups = list(_DEFAULT_FIXUPS)
        self.style = "Standard"
        self.load()

    def load(self):
        if SETTINGS_FILE.exists():
            try:
                data = json.loads(SETTINGS_FILE.read_text())
                self.vocab = data.get("vocab", list(_DEFAULT_VOCAB))
                self.fixups = data.get("fixups", list(_DEFAULT_FIXUPS))
                s = data.get("style", "Standard")
                self.style = s if s in self.STYLES else "Standard"
            except (json.JSONDecodeError, OSError):
                pass

    def save(self):
        SETTINGS_DIR.mkdir(parents=True, exist_ok=True)
        SETTINGS_FILE.write_text(json.dumps(
            {"vocab": self.vocab, "fixups": self.fixups, "style": self.style},
            indent=2,
        ))

    def vocab_string(self):
        return ", ".join(self.vocab)

    def fixups_compiled(self):
        compiled = []
        for f in self.fixups:
            try:
                escaped = re.escape(f["from"])
                pattern = re.compile(
                    r'\b' + escaped.replace(r'\ ', r'\s+') + r'\b',
                    re.IGNORECASE,
                )
                compiled.append((pattern, f["to"]))
            except re.error:
                pass
        return compiled


settings = Settings()


class _AppDelegate(NSObject):
    """Prevent app from quitting when preferences window closes."""

    def applicationShouldTerminateAfterLastWindowClosed_(self, app):
        return False


# --- Preferences Window ---

class _PrefsController(NSObject):
    """Manages the Preferences window."""

    def init(self):
        self = objc.super(_PrefsController, self).init()
        if self is None:
            return None
        self._window = None
        self._vocab_tv = None
        self._fixups_tv = None
        return self

    def showWindow_(self, sender):
        if self._window is not None:
            self._window.makeKeyAndOrderFront_(None)
            NSApp.activateIgnoringOtherApps_(True)
            return

        W, H = 480, 560
        PAD = 20
        style = 1 | 2  # Titled | Closable

        window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            ((0, 0), (W, H)), style, 2, False
        )
        window.setTitle_("LokaVox Preferences")
        window.setReleasedWhenClosed_(False)
        window.center()
        window.setDelegate_(self)

        content = window.contentView()
        y = H - 30

        # Writing Style section
        y = self._add_label(content, "Writing Style", True, y, W)
        _style_desc = {
            "Standard": "Proper capitalization and punctuation",
            "Lowercase": "All lowercase, punctuation kept",
        }
        y = self._add_label(
            content, _style_desc.get(settings.style, ""), False, y, W
        )
        self._style_popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(
            ((PAD, y - 28), (W - PAD * 2, 28)), False
        )
        self._style_popup.addItemsWithTitles_(Settings.STYLES)
        self._style_popup.selectItemWithTitle_(settings.style)
        content.addSubview_(self._style_popup)
        y -= 44

        # Vocabulary section
        y = self._add_label(content, "Vocabulary", True, y, W)
        y = self._add_label(content, "One word or phrase per line", False, y, W)
        self._vocab_tv, y = self._add_text_area(content, y - 4, W, 160)
        self._vocab_tv.setString_("\n".join(settings.vocab))

        y -= 16

        # Corrections section
        y = self._add_label(content, "Corrections", True, y, W)
        y = self._add_label(
            content, "One per line:  wrong >> right", False, y, W
        )
        self._fixups_tv, y = self._add_text_area(content, y - 4, W, 160)
        lines = [f'{f["from"]} >> {f["to"]}' for f in settings.fixups]
        self._fixups_tv.setString_("\n".join(lines))

        self._window = window
        window.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)

    def _add_label(self, parent, text, bold, y, w):
        PAD = 20
        h = 18 if bold else 14
        size = 13 if bold else 11
        label = NSTextField.alloc().initWithFrame_(
            ((PAD, y - h), (w - PAD * 2, h))
        )
        label.setStringValue_(text)
        label.setBezeled_(False)
        label.setDrawsBackground_(False)
        label.setEditable_(False)
        label.setSelectable_(False)
        if bold:
            label.setFont_(NSFont.boldSystemFontOfSize_(size))
        else:
            label.setFont_(NSFont.systemFontOfSize_(size))
            label.setTextColor_(NSColor.secondaryLabelColor())
        parent.addSubview_(label)
        return y - h - 2

    def _add_text_area(self, parent, y, w, h):
        PAD = 20
        scroll = NSScrollView.alloc().initWithFrame_(
            ((PAD, y - h), (w - PAD * 2, h))
        )
        scroll.setHasVerticalScroller_(True)
        scroll.setBorderType_(2)  # NSBezelBorder

        cs = scroll.contentSize()
        tv = NSTextView.alloc().initWithFrame_(((0, 0), (cs.width, cs.height)))
        tv.setFont_(NSFont.monospacedSystemFontOfSize_weight_(12, 0))
        tv.setVerticallyResizable_(True)
        tv.setHorizontallyResizable_(False)
        tv.textContainer().setWidthTracksTextView_(True)
        scroll.setDocumentView_(tv)
        parent.addSubview_(scroll)
        return tv, y - h

    def windowShouldClose_(self, sender):
        # Save style
        settings.style = str(self._style_popup.titleOfSelectedItem())

        # Save vocabulary
        text = str(self._vocab_tv.string())
        settings.vocab = [l.strip() for l in text.split("\n") if l.strip()]

        # Save corrections
        text = str(self._fixups_tv.string())
        settings.fixups = []
        for line in text.split("\n"):
            line = line.strip()
            if not line:
                continue
            sep = ">>" if ">>" in line else "\u2192" if "\u2192" in line else None
            if sep is None:
                continue
            parts = line.split(sep, 1)
            f, t = parts[0].strip(), parts[1].strip()
            if f and t:
                settings.fixups.append({"from": f, "to": t})

        settings.save()
        self._window.orderOut_(None)  # Hide, don't close
        return False  # Prevent actual window close


class MenuBar:
    """macOS menu bar indicator for recording state."""

    def __init__(self):
        self.status_item = NSStatusBar.systemStatusBar().statusItemWithLength_(
            NSVariableStatusItemLength
        )
        # Load template images — macOS auto-adapts color to light/dark theme
        res = str(Path(__file__).parent / "resources")
        self._icons = {}
        for name in ("mic_idle", "mic_recording", "mic_transcribing"):
            img = NSImage.alloc().initWithContentsOfFile_(f"{res}/{name}.png")
            if img:
                img.setSize_((22, 22))
                img.setTemplate_(True)
            self._icons[name] = img

        self.status_item.setImage_(self._icons.get("mic_idle"))

        self._prefs = _PrefsController.alloc().init()

        menu = NSMenu.alloc().init()
        prefs_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Preferences\u2026", "showWindow:", ","
        )
        prefs_item.setTarget_(self._prefs)
        menu.addItem_(prefs_item)
        menu.addItem_(NSMenuItem.separatorItem())
        quit_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Quit", "terminate:", "q"
        )
        menu.addItem_(quit_item)
        self.status_item.setMenu_(menu)

    def _set(self, name):
        img = self._icons.get(name)
        if img:
            AppHelper.callAfter(self.status_item.setImage_, img)

    def recording(self):
        self._set("mic_recording")

    def transcribing(self):
        self._set("mic_transcribing")

    def idle(self):
        self._set("mic_idle")


class LokaVox:
    def __init__(self, language="auto"):
        self.language = language
        self.menubar = None
        self.recording = False
        self.transcribing = False
        self.sox_process = None
        self.audio_file = None
        self.toggle_active = False
        self._f5_held = False
        self._stop_timer = None
        self._tap = None
        self._media_was_playing = False
        self._playing_app = None
        self._recording_start = 0

    def preflight(self):
        missing = []
        for cmd in ["whisper-cli", "sox"]:
            if subprocess.run(["which", cmd], capture_output=True).returncode != 0:
                missing.append(cmd)
        if missing:
            print(f"Missing: {', '.join(missing)}")
            print(f"Install: brew install {' '.join(missing)}")
            sys.exit(1)
        if not MODEL.exists():
            print(f"Model not found: {MODEL}")
            sys.exit(1)

    def _pause_media(self):
        """Pause Spotify or Music if playing. Won't launch Apple Music."""
        self._media_was_playing = False
        self._playing_app = None
        try:
            result = subprocess.run(
                ["osascript", "-e", _PAUSE_SCRIPT],
                capture_output=True, text=True, timeout=2,
            )
            app = result.stdout.strip()
            if app and app != "none":
                self._media_was_playing = True
                self._playing_app = app
        except (subprocess.TimeoutExpired, Exception):
            pass

    def _resume_media(self):
        """Resume media only if we paused it."""
        if not self._media_was_playing or not self._playing_app:
            return
        app = self._playing_app
        if app in _NATIVE_APPS:
            script = f'tell application "{app}" to play'
        elif app in _CHROMIUM_BROWSERS:
            script = (
                f'tell application "{app}"\n'
                f'    repeat with w in windows\n'
                f'        repeat with t in tabs of w\n'
                f'            try\n'
                f'                execute t javascript "{_JS_RESUME}"\n'
                f'            end try\n'
                f'        end repeat\n'
                f'    end repeat\n'
                f'end tell'
            )
        elif app == "Safari":
            script = (
                f'tell application "Safari"\n'
                f'    repeat with w in windows\n'
                f'        repeat with t in tabs of w\n'
                f'            try\n'
                f'                do JavaScript "{_JS_RESUME}" in t\n'
                f'            end try\n'
                f'        end repeat\n'
                f'    end repeat\n'
                f'end tell'
            )
        else:
            self._media_was_playing = False
            self._playing_app = None
            return
        try:
            subprocess.run(
                ["osascript", "-e", script],
                capture_output=True, timeout=2,
            )
        except (subprocess.TimeoutExpired, Exception):
            pass
        self._media_was_playing = False
        self._playing_app = None

    def start_recording(self):
        if self.recording or self.transcribing:
            return
        self._pause_media()
        self.audio_file = tempfile.NamedTemporaryFile(
            suffix=".wav", prefix="lokavox-", delete=False
        ).name
        self.sox_process = subprocess.Popen(
            ["sox", "-d", "-r", str(SAMPLE_RATE), "-c", "1", "-b", "16", self.audio_file],
            stderr=subprocess.DEVNULL,
        )
        self.recording = True
        self._recording_start = time.monotonic()
        if self.menubar:
            self.menubar.recording()

    def stop_recording(self):
        if not self.recording:
            return None
        duration = time.monotonic() - self._recording_start
        self.recording = False
        if self.sox_process:
            self.sox_process.terminate()
            self.sox_process.wait()
            self.sox_process = None
        self._resume_media()
        if duration < MIN_RECORDING_SECS:
            self.cleanup()
            if self.menubar:
                self.menubar.idle()
            return None
        if self.menubar:
            self.menubar.transcribing()
        return self.audio_file

    def transcribe(self, audio_path):
        if not audio_path or not os.path.exists(audio_path):
            return ""
        if os.path.getsize(audio_path) < 1000:
            return ""
        cmd = [
            "whisper-cli",
            "-m", str(MODEL),
            "-l", self.language,
            "-nt",
            "--prompt", settings.vocab_string(),
            "-f", audio_path,
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            text = " ".join(result.stdout.strip().split())
            if text.lower().rstrip(".!,") in _HALLUCINATIONS:
                return ""
            for pattern, replacement in settings.fixups_compiled():
                text = pattern.sub(replacement, text)
            # Apply writing style
            if settings.style == "Lowercase":
                text = text.lower()
            return text
        except subprocess.TimeoutExpired:
            return ""
        except Exception:
            return ""

    def paste(self, text):
        if not text:
            return
        subprocess.run(["pbcopy"], input=text.encode(), check=True)
        time.sleep(0.05)
        source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
        cmd_v_down = Quartz.CGEventCreateKeyboardEvent(source, 9, True)
        Quartz.CGEventSetFlags(cmd_v_down, Quartz.kCGEventFlagMaskCommand)
        cmd_v_up = Quartz.CGEventCreateKeyboardEvent(source, 9, False)
        Quartz.CGEventSetFlags(cmd_v_up, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, cmd_v_down)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, cmd_v_up)

    def cleanup(self):
        if self.audio_file and os.path.exists(self.audio_file):
            os.unlink(self.audio_file)
            self.audio_file = None

    def _transcribe_and_paste(self, audio_path):
        self.transcribing = True
        try:
            text = self.transcribe(audio_path)
            if text:
                self.paste(text)
        finally:
            self.cleanup()
            self.transcribing = False
            if self.menubar:
                self.menubar.idle()

    def _handle_stop(self):
        audio_path = self.stop_recording()
        if audio_path:
            threading.Thread(
                target=self._transcribe_and_paste, args=(audio_path,)
            ).start()

    def _event_callback(self, proxy, event_type, event, refcon):
        # Re-enable tap if macOS disabled it due to slow callback
        if event_type == Quartz.kCGEventTapDisabledByTimeout:
            Quartz.CGEventTapEnable(self._tap, True)
            return event

        keycode = Quartz.CGEventGetIntegerValueField(
            event, Quartz.kCGKeyboardEventKeycode
        )

        if keycode == KEYCODE_DICTATION:
            if event_type == Quartz.kCGEventKeyDown:
                self._on_f5_down()
            elif event_type == Quartz.kCGEventKeyUp:
                self._on_f5_up()
            return None  # Suppress F5 — don't trigger macOS dictation

        return event

    def _on_f5_down(self):
        if self._f5_held:
            return  # Key repeat — ignore
        self._f5_held = True

        # Cancel pending stop — this is the second tap of a double-tap
        if self._stop_timer:
            self._stop_timer.cancel()
            self._stop_timer = None
            if self.recording:
                self.toggle_active = True
                return

        if self.toggle_active and self.recording:
            self._handle_stop()
            self.toggle_active = False
        elif not self.recording and not self.transcribing:
            self.toggle_active = False
            self.start_recording()

    def _on_f5_up(self):
        self._f5_held = False
        if self.recording and not self.toggle_active:
            # Delay stop to allow double-tap detection
            self._stop_timer = threading.Timer(
                DOUBLE_TAP_WINDOW, self._delayed_stop
            )
            self._stop_timer.start()

    def _delayed_stop(self):
        self._stop_timer = None
        if self.recording and not self.toggle_active:
            self._handle_stop()

    def run(self):
        self.preflight()

        print("LokaVox ready.")
        print("  Hold F5 → hold-to-talk")
        print("  Double-tap F5 → toggle recording on/off")
        print(f"  Language: {self.language}")
        print(f"  Model: {MODEL.name}")
        print()

        # Menu bar
        app = NSApplication.sharedApplication()
        app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
        self._app_delegate = _AppDelegate.alloc().init()
        app.setDelegate_(self._app_delegate)
        self.menubar = MenuBar()

        # CGEventTap — intercepts keyboard events, can suppress them
        mask = (
            Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventKeyUp)
        )

        self._tap = Quartz.CGEventTapCreate(
            Quartz.kCGSessionEventTap,
            Quartz.kCGHeadInsertEventTap,
            Quartz.kCGEventTapOptionDefault,
            mask,
            self._event_callback,
            None,
        )

        if self._tap is None:
            print("Failed to create event tap.")
            print("Grant Accessibility permission in:")
            print("  System Settings → Privacy & Security → Accessibility")
            sys.exit(1)

        source = Quartz.CFMachPortCreateRunLoopSource(None, self._tap, 0)
        Quartz.CFRunLoopAddSource(
            Quartz.CFRunLoopGetMain(), source, Quartz.kCFRunLoopDefaultMode
        )
        Quartz.CGEventTapEnable(self._tap, True)

        signal.signal(signal.SIGINT, lambda *_: AppHelper.stopEventLoop())

        AppHelper.runEventLoop()

        if self.recording:
            self.stop_recording()
            self.cleanup()


def main():
    parser = argparse.ArgumentParser(
        description="Local push-to-talk dictation with whisper.cpp",
    )
    parser.add_argument(
        "--lang", default="auto",
        help="Language: auto, en, tr, etc. (default: auto)",
    )
    args = parser.parse_args()

    LokaVox(language=args.lang).run()


if __name__ == "__main__":
    main()
