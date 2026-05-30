#!/usr/bin/env python3
"""
lokavox.py — Local push-to-talk dictation using whisper.cpp

Default hotkey:
    Hold Control (either side)   push-to-talk
    Control + Escape             toggle recording on/off

Alternative hotkey (change in Preferences):
    Hold F5 / dictation key      push-to-talk
    Double-tap F5                toggle recording on/off

Pauses media playback (Spotify, Apple Music, Brave/Chrome/Safari video)
while recording and resumes after. Menu bar shows state: outline mic
(idle), filled mic (recording), mic+dots (transcribing).

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
    from Foundation import NSObject, NSCharacterSet, NSTimer
    from AppKit import (
        NSApplication,
        NSImage,
        NSStatusBar,
        NSVariableStatusItemLength,
        NSMenu,
        NSMenuItem,
        NSApplicationActivationPolicyAccessory,
        NSWindow,
        NSView,
        NSTextField,
        NSTextView,
        NSTokenField,
        NSScrollView,
        NSColor,
        NSFont,
        NSPopUpButton,
        NSButton,
        NSBox,
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

# Launch at Login via LaunchAgent (survives re-codesigning, unlike Login Items)
_LAUNCH_AGENT_DIR = Path.home() / "Library" / "LaunchAgents"
_LAUNCH_AGENT_FILE = _LAUNCH_AGENT_DIR / "com.local.lokavox.plist"

# macOS key codes
KEYCODE_LEFT_CTRL = 59
KEYCODE_RIGHT_CTRL = 62
KEYCODE_ESCAPE = 53       # Universal across keyboard layouts
KEYCODE_DICTATION = 176   # Dedicated mic/dictation key on modern Macs

# Timing
HOLD_DELAY = 0.25         # Hold modifier this long before recording starts
DOUBLE_TAP_WINDOW = 0.35  # F5 mode double-tap toggle window
MIN_RECORDING_SECS = 0.7  # Ignore accidentally short recordings

# Audio energy gate. A capture whose RMS amplitude is below this is treated as
# silence (e.g. sox recorded zeros because Microphone permission never reached
# the child process). Speech is typically > 0.01; true silence is ~0. Gating
# here stops whisper from echoing the --prompt vocab on silence.
SILENCE_RMS_THRESHOLD = 0.003

# Hotkey modes
HOTKEY_CONTROL = "Control"
HOTKEY_DICTATION = "Dictation Key (F5 row)"
HOTKEY_MODES = [HOTKEY_CONTROL, HOTKEY_DICTATION]

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
        self.hotkey = HOTKEY_CONTROL
        self.load()

    def load(self):
        if SETTINGS_FILE.exists():
            try:
                data = json.loads(SETTINGS_FILE.read_text())
                self.vocab = data.get("vocab", list(_DEFAULT_VOCAB))
                self.fixups = data.get("fixups", list(_DEFAULT_FIXUPS))
                s = data.get("style", "Standard")
                self.style = s if s in self.STYLES else "Standard"
                h = data.get("hotkey", HOTKEY_CONTROL)
                self.hotkey = h if h in HOTKEY_MODES else HOTKEY_CONTROL
            except (json.JSONDecodeError, OSError):
                pass

    def save(self):
        SETTINGS_DIR.mkdir(parents=True, exist_ok=True)
        SETTINGS_FILE.write_text(json.dumps({
            "vocab": self.vocab,
            "fixups": self.fixups,
            "style": self.style,
            "hotkey": self.hotkey,
        }, indent=2))

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


# --- Login Item Management ---

def _login_item_enabled():
    """Check if launch-at-login is enabled (LaunchAgent plist exists)."""
    return _LAUNCH_AGENT_FILE.exists()


def _set_login_item(enabled):
    """Enable or disable launch-at-login via LaunchAgent."""
    if enabled:
        _LAUNCH_AGENT_DIR.mkdir(parents=True, exist_ok=True)
        app_path = Path.home() / "Applications" / "LokaVox.app"
        plist = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
            ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n'
            '<dict>\n'
            '    <key>Label</key>\n'
            '    <string>com.local.lokavox</string>\n'
            '    <key>ProgramArguments</key>\n'
            '    <array>\n'
            '        <string>open</string>\n'
            '        <string>-a</string>\n'
            f'        <string>{app_path}</string>\n'
            '    </array>\n'
            '    <key>RunAtLoad</key>\n'
            '    <true/>\n'
            '</dict>\n'
            '</plist>\n'
        )
        _LAUNCH_AGENT_FILE.write_text(plist)
    else:
        if _LAUNCH_AGENT_FILE.exists():
            _LAUNCH_AGENT_FILE.unlink()


class _AppDelegate(NSObject):
    """Prevent app from quitting when preferences window closes."""

    def applicationShouldTerminateAfterLastWindowClosed_(self, app):
        return False


class _FlippedView(NSView):
    """Plain NSView with top-down coordinates (origin at top-left)."""

    def isFlipped(self):
        return True


# --- Preferences Window ---

class _PrefsController(NSObject):
    """Manages the Preferences window."""

    def init(self):
        self = objc.super(_PrefsController, self).init()
        if self is None:
            return None
        self._window = None
        self._hotkey_popup = None
        self._style_popup = None
        self._vocab_tokens = None
        self._fixups_doc = None
        self._fixups_rows = []
        self._saved_label = None
        self._saved_timer = None
        self._login_checkbox = None
        return self

    def showWindow_(self, sender):
        if self._window is not None:
            self._sync_from_settings()
            self._window.makeKeyAndOrderFront_(None)
            NSApp.activateIgnoringOtherApps_(True)
            return

        W, H = 520, 810
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

        # --- Hotkey section ---
        y = self._add_label(content, "Hotkey", True, y, W)
        y = self._add_multiline(
            content,
            "Control: hold either Control key to talk, Control+Escape "
            "to toggle recording on/off.",
            y, W, lines=2,
        )
        self._hotkey_popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(
            ((PAD, y - 28), (W - PAD * 2, 28)), False
        )
        self._hotkey_popup.addItemsWithTitles_(HOTKEY_MODES)
        self._hotkey_popup.selectItemWithTitle_(settings.hotkey)
        content.addSubview_(self._hotkey_popup)
        y -= 40
        y = self._add_separator(content, y, W)

        # --- Writing Style section ---
        y = self._add_label(content, "Writing Style", True, y, W)
        y = self._add_multiline(
            content,
            "Standard = proper capitalization and punctuation. "
            "Lowercase = all lowercase, punctuation kept.",
            y, W, lines=2,
        )
        self._style_popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(
            ((PAD, y - 28), (W - PAD * 2, 28)), False
        )
        self._style_popup.addItemsWithTitles_(Settings.STYLES)
        self._style_popup.selectItemWithTitle_(settings.style)
        content.addSubview_(self._style_popup)
        y -= 40
        y = self._add_separator(content, y, W)

        # --- Vocabulary section ---
        y = self._add_label(content, "Vocabulary", True, y, W)
        y = self._add_multiline(
            content,
            "Words or phrases to help Whisper recognize names, products, "
            "and jargon. Type and press Enter or comma to add a token.",
            y, W, lines=2,
        )
        token_h = 80
        self._vocab_tokens = NSTokenField.alloc().initWithFrame_(
            ((PAD, y - token_h), (W - PAD * 2, token_h))
        )
        charset = NSCharacterSet.characterSetWithCharactersInString_(",\n")
        self._vocab_tokens.setTokenizingCharacterSet_(charset)
        self._vocab_tokens.setObjectValue_(list(settings.vocab))
        content.addSubview_(self._vocab_tokens)
        y -= token_h + 12
        y = self._add_separator(content, y, W)

        # --- Corrections section ---
        y = self._add_label(content, "Corrections", True, y, W)
        y = self._add_multiline(
            content,
            "Find-and-replace rules applied after transcription. "
            'Click "+ Add correction" to create a rule.',
            y, W, lines=2,
        )
        scroll_h = 110
        doc_w = W - PAD * 2 - 20  # account for vertical scroll bar
        fixups_scroll = NSScrollView.alloc().initWithFrame_(
            ((PAD, y - scroll_h), (W - PAD * 2, scroll_h))
        )
        fixups_scroll.setHasVerticalScroller_(True)
        fixups_scroll.setBorderType_(2)  # NSBezelBorder
        doc_view = _FlippedView.alloc().initWithFrame_(((0, 0), (doc_w, 40)))
        fixups_scroll.setDocumentView_(doc_view)
        content.addSubview_(fixups_scroll)
        self._fixups_doc = doc_view
        self._fixups_rows = []
        for f in settings.fixups:
            self._build_fixup_row(f.get("from", ""), f.get("to", ""))
        self._relayout_fixup_rows()
        y -= scroll_h + 8

        add_fixup_btn = NSButton.alloc().initWithFrame_(
            ((PAD, y - 26), (150, 26))
        )
        add_fixup_btn.setTitle_("+ Add correction")
        add_fixup_btn.setBezelStyle_(1)
        add_fixup_btn.setTarget_(self)
        add_fixup_btn.setAction_("addFixupClicked:")
        content.addSubview_(add_fixup_btn)
        y -= 34

        # --- Launch at Login ---
        y = self._add_separator(content, y, W)
        self._login_checkbox = NSButton.alloc().initWithFrame_(
            ((PAD, y - 22), (W - PAD * 2, 22))
        )
        self._login_checkbox.setButtonType_(3)  # NSSwitchButton
        self._login_checkbox.setTitle_("Launch at Login")
        self._login_checkbox.setState_(1 if _login_item_enabled() else 0)
        content.addSubview_(self._login_checkbox)
        y -= 34

        # --- Save button + saved-feedback label ---
        btn_w, btn_h = 90, 30
        save_btn = NSButton.alloc().initWithFrame_(
            ((W - PAD - btn_w, y - btn_h), (btn_w, btn_h))
        )
        save_btn.setTitle_("Save")
        save_btn.setBezelStyle_(1)  # NSRoundedBezelStyle
        save_btn.setKeyEquivalent_("\r")  # Default button, Enter key
        save_btn.setTarget_(self)
        save_btn.setAction_("saveClicked:")
        content.addSubview_(save_btn)

        saved_label = NSTextField.alloc().initWithFrame_(
            ((PAD, y - btn_h + 6), (W - PAD * 2 - btn_w - 10, 20))
        )
        saved_label.setStringValue_("")
        saved_label.setBezeled_(False)
        saved_label.setDrawsBackground_(False)
        saved_label.setEditable_(False)
        saved_label.setSelectable_(False)
        saved_label.setFont_(NSFont.systemFontOfSize_(12))
        saved_label.setTextColor_(NSColor.secondaryLabelColor())
        content.addSubview_(saved_label)
        self._saved_label = saved_label

        self._window = window
        window.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)

    def _sync_from_settings(self):
        """Refresh UI fields from current settings (used when re-showing window)."""
        if self._hotkey_popup is not None:
            self._hotkey_popup.selectItemWithTitle_(settings.hotkey)
        if self._style_popup is not None:
            self._style_popup.selectItemWithTitle_(settings.style)
        if self._vocab_tokens is not None:
            self._vocab_tokens.setObjectValue_(list(settings.vocab))
        if self._fixups_doc is not None:
            # Wipe existing row widgets, rebuild from settings
            for row in self._fixups_rows:
                for widget in (row["from"], row["arrow"], row["to"], row["remove"]):
                    widget.removeFromSuperview()
            self._fixups_rows = []
            for f in settings.fixups:
                self._build_fixup_row(f.get("from", ""), f.get("to", ""))
            self._relayout_fixup_rows()
        if self._login_checkbox is not None:
            self._login_checkbox.setState_(1 if _login_item_enabled() else 0)

    def saveClicked_(self, sender):
        self._commit()
        self._show_saved_feedback()

    def _show_saved_feedback(self):
        if self._saved_label is None:
            return
        self._saved_label.setStringValue_("✓ Saved")
        self._saved_label.setTextColor_(NSColor.systemGreenColor())
        if self._saved_timer:
            self._saved_timer.cancel()
        t = threading.Timer(1.5, self._clear_saved_feedback)
        t.daemon = True
        t.start()
        self._saved_timer = t

    def _clear_saved_feedback(self):
        def clear():
            if self._saved_label is not None:
                self._saved_label.setStringValue_("")
        AppHelper.callAfter(clear)

    def _commit(self):
        # Hotkey
        if self._hotkey_popup is not None:
            h = str(self._hotkey_popup.titleOfSelectedItem())
            if h in HOTKEY_MODES:
                settings.hotkey = h

        # Style
        if self._style_popup is not None:
            settings.style = str(self._style_popup.titleOfSelectedItem())

        # Vocabulary (NSTokenField objectValue is an NSArray of strings)
        if self._vocab_tokens is not None:
            tokens = self._vocab_tokens.objectValue() or []
            settings.vocab = [str(t).strip() for t in tokens if str(t).strip()]

        # Corrections (row widgets)
        settings.fixups = []
        for row in self._fixups_rows:
            f = str(row["from"].stringValue()).strip()
            t = str(row["to"].stringValue()).strip()
            if f and t:
                settings.fixups.append({"from": f, "to": t})

        settings.save()

        # Launch at Login
        if self._login_checkbox is not None:
            _set_login_item(self._login_checkbox.state() == 1)

    def _add_separator(self, parent, y, w):
        PAD = 20
        sep = NSBox.alloc().initWithFrame_(
            ((PAD, y - 10), (w - PAD * 2, 1))
        )
        sep.setBoxType_(2)  # NSBoxSeparator
        parent.addSubview_(sep)
        return y - 18

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
        return y - h - 3

    def _add_multiline(self, parent, text, y, w, lines=2):
        PAD = 20
        line_h = 14
        h = line_h * lines
        label = NSTextField.alloc().initWithFrame_(
            ((PAD, y - h), (w - PAD * 2, h))
        )
        label.setStringValue_(text)
        label.setBezeled_(False)
        label.setDrawsBackground_(False)
        label.setEditable_(False)
        label.setSelectable_(False)
        label.setFont_(NSFont.systemFontOfSize_(11))
        label.setTextColor_(NSColor.secondaryLabelColor())
        label.cell().setWraps_(True)
        label.cell().setScrollable_(False)
        parent.addSubview_(label)
        return y - h - 4

    # --- Corrections row management ---

    def _build_fixup_row(self, from_text="", to_text=""):
        """Create widgets for one correction row. Caller must call
        _relayout_fixup_rows() after to position them."""
        doc = self._fixups_doc
        if doc is None:
            return
        doc_w = doc.frame().size.width
        row_h = 22
        arrow_w = 22
        remove_w = 26
        pad = 6
        # Split remaining width between from and to fields 50/50
        fields_w = doc_w - arrow_w - remove_w - pad * 4
        from_w = max(60, int(fields_w * 0.5))
        to_w = max(60, fields_w - from_w)

        x = pad
        from_field = NSTextField.alloc().initWithFrame_(
            ((x, 0), (from_w, row_h))
        )
        from_field.setStringValue_(from_text)
        try:
            from_field.cell().setPlaceholderString_("wrong")
        except Exception:
            pass
        doc.addSubview_(from_field)
        x += from_w + pad

        arrow = NSTextField.alloc().initWithFrame_(
            ((x, 2), (arrow_w, row_h - 4))
        )
        arrow.setStringValue_("→")
        arrow.setBezeled_(False)
        arrow.setDrawsBackground_(False)
        arrow.setEditable_(False)
        arrow.setSelectable_(False)
        arrow.setAlignment_(2)  # NSTextAlignmentCenter
        arrow.setTextColor_(NSColor.secondaryLabelColor())
        doc.addSubview_(arrow)
        x += arrow_w + pad

        to_field = NSTextField.alloc().initWithFrame_(
            ((x, 0), (to_w, row_h))
        )
        to_field.setStringValue_(to_text)
        try:
            to_field.cell().setPlaceholderString_("right")
        except Exception:
            pass
        doc.addSubview_(to_field)
        x += to_w + pad

        remove_btn = NSButton.alloc().initWithFrame_(
            ((x, 0), (remove_w, row_h))
        )
        remove_btn.setTitle_("×")
        remove_btn.setBezelStyle_(1)
        remove_btn.setTarget_(self)
        remove_btn.setAction_("removeFixupClicked:")
        doc.addSubview_(remove_btn)

        self._fixups_rows.append({
            "from": from_field,
            "arrow": arrow,
            "to": to_field,
            "remove": remove_btn,
        })

    def _relayout_fixup_rows(self):
        doc = self._fixups_doc
        if doc is None:
            return
        stride = 28  # row_h (22) + gap (6)
        for i, row in enumerate(self._fixups_rows):
            base_y = i * stride
            for key, w in row.items():
                frame = w.frame()
                if key == "arrow":
                    w.setFrameOrigin_((frame.origin.x, base_y + 2))
                else:
                    w.setFrameOrigin_((frame.origin.x, base_y))
        doc_w = doc.frame().size.width
        new_h = max(len(self._fixups_rows) * stride, 40)
        doc.setFrameSize_((doc_w, new_h))

    def addFixupClicked_(self, sender):
        self._build_fixup_row("", "")
        self._relayout_fixup_rows()
        # Scroll the newly added row into view
        if self._fixups_rows:
            last = self._fixups_rows[-1]["from"]
            self._fixups_doc.scrollRectToVisible_(last.frame())
            # Focus the new from-field so the user can start typing immediately
            self._window.makeFirstResponder_(last)

    def removeFixupClicked_(self, sender):
        for i, row in enumerate(self._fixups_rows):
            if row["remove"] == sender:
                for widget in (row["from"], row["arrow"], row["to"], row["remove"]):
                    widget.removeFromSuperview()
                del self._fixups_rows[i]
                self._relayout_fixup_rows()
                return

    def windowShouldClose_(self, sender):
        # Auto-save on close as a safety net.
        self._commit()
        self._window.orderOut_(None)
        return False


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

        # Animation state for the transcribing phase (a breathing pulse so it
        # reads as "working", distinct from the solid recording icon).
        self._anim_timer = None
        self._anim_index = 0
        self._anim_frames = self._build_pulse_frames("mic_transcribing")

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

    def _build_pulse_frames(self, name):
        """Pre-render a 'breathing' pulse of the given icon by drawing it at
        varying opacity, so the transcribing state animates instead of sitting
        static. Frames stay template images so macOS keeps theming them."""
        base = self._icons.get(name)
        if not base:
            return []
        size = base.size()
        rect = ((0.0, 0.0), (size.width, size.height))
        fractions = [1.0, 0.8, 0.55, 0.35, 0.25, 0.35, 0.55, 0.8]
        frames = []
        for frac in fractions:
            frame = NSImage.alloc().initWithSize_(size)
            frame.lockFocus()
            # 2 = NSCompositingOperationSourceOver
            base.drawInRect_fromRect_operation_fraction_(rect, rect, 2, frac)
            frame.unlockFocus()
            frame.setTemplate_(True)
            frames.append(frame)
        return frames

    # --- State transitions (always marshalled to the main thread) ---

    def recording(self):
        AppHelper.callAfter(self._show_static, "mic_recording")

    def transcribing(self):
        AppHelper.callAfter(self._start_anim)

    def idle(self):
        AppHelper.callAfter(self._show_static, "mic_idle")

    # --- Main-thread implementations ---

    def _show_static(self, name):
        self._stop_anim()
        img = self._icons.get(name)
        if img:
            self.status_item.setImage_(img)

    def _start_anim(self):
        self._stop_anim()
        if not self._anim_frames:
            self._show_static("mic_transcribing")
            return
        self.status_item.setImage_(self._anim_frames[0])
        self._anim_index = 1

        def tick(timer):
            frames = self._anim_frames
            self.status_item.setImage_(frames[self._anim_index % len(frames)])
            self._anim_index += 1

        self._anim_timer = NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
            0.11, True, tick
        )

    def _stop_anim(self):
        if self._anim_timer is not None:
            self._anim_timer.invalidate()
            self._anim_timer = None


class LokaVox:
    def __init__(self, language="auto"):
        self.language = language
        self.menubar = None
        self.recording = False
        self.transcribing = False
        self.toggle_active = False
        self.sox_process = None
        self.audio_file = None
        self._tap = None
        self._media_was_playing = False
        self._playing_app = None
        self._recording_start = 0

        # Control-mode state
        self._ctrl_held = False
        self._start_timer = None   # Hold-delay timer before PTT starts

        # F5-mode state
        self._f5_held = False
        self._stop_timer = None    # Double-tap wait timer

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

    def _detect_language(self, audio_path):
        # Run whisper-cli with -dl to detect language without prompt bias.
        # The vocab prompt skews auto-detection (Turkish words tip English audio
        # toward Turkish on short/ambiguous clips), so detect first without it.
        cmd = [
            "whisper-cli",
            "-m", str(MODEL),
            "-l", "auto",
            "-dl",
            "-f", audio_path,
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            for line in result.stderr.splitlines():
                if "auto-detected language:" in line:
                    parts = line.split("auto-detected language:")[1].strip().split()
                    if parts:
                        return parts[0]
        except Exception:
            pass
        return None

    def _is_silent(self, audio_path):
        """True if the capture is essentially silent — e.g. sox recorded zeros
        because Microphone permission never reached the child process. Gating
        here stops whisper echoing the --prompt vocab on silence."""
        try:
            result = subprocess.run(
                ["sox", audio_path, "-n", "stat"],
                capture_output=True, text=True, timeout=10,
            )
            for line in result.stderr.splitlines():
                if "RMS" in line and "amplitude" in line:
                    return float(line.split(":")[1]) < SILENCE_RMS_THRESHOLD
        except Exception:
            pass
        return False

    def _is_vocab_echo(self, text):
        """True if the transcript is nothing but vocab/prompt tokens — whisper
        echoing the --prompt back on near-silent audio (the 'Claude Claude'
        failure that the _HALLUCINATIONS denylist does not cover)."""
        vocab_words = {
            w.strip(".,!?").lower()
            for phrase in settings.vocab
            for w in phrase.split()
            if w.strip(".,!?")
        }
        if not vocab_words:
            return False
        words = [w.strip(".,!?").lower() for w in text.split() if w.strip(".,!?")]
        return bool(words) and all(w in vocab_words for w in words)

    def transcribe(self, audio_path):
        if not audio_path or not os.path.exists(audio_path):
            return ""
        if os.path.getsize(audio_path) < 1000:
            return ""
        if self._is_silent(audio_path):
            return ""
        lang = self.language
        if lang == "auto":
            detected = self._detect_language(audio_path)
            if detected:
                lang = detected
        cmd = [
            "whisper-cli",
            "-m", str(MODEL),
            "-l", lang,
            "-nt",
            "--prompt", settings.vocab_string(),
            "-f", audio_path,
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            text = " ".join(result.stdout.strip().split())
            if text.lower().rstrip(".!,") in _HALLUCINATIONS:
                return ""
            if self._is_vocab_echo(text):
                return ""
            for pattern, replacement in settings.fixups_compiled():
                text = pattern.sub(replacement, text)
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

    # --- Event tap ---

    def _event_callback(self, proxy, event_type, event, refcon):
        if event_type == Quartz.kCGEventTapDisabledByTimeout:
            Quartz.CGEventTapEnable(self._tap, True)
            return event

        keycode = Quartz.CGEventGetIntegerValueField(
            event, Quartz.kCGKeyboardEventKeycode
        )
        flags = Quartz.CGEventGetFlags(event)
        mode = settings.hotkey

        if mode == HOTKEY_CONTROL:
            # Control modifier press/release
            if event_type == Quartz.kCGEventFlagsChanged and keycode in (
                KEYCODE_LEFT_CTRL, KEYCODE_RIGHT_CTRL
            ):
                ctrl_now = bool(flags & Quartz.kCGEventFlagMaskControl)
                if ctrl_now and not self._ctrl_held:
                    self._on_ctrl_down()
                elif not ctrl_now and self._ctrl_held:
                    self._on_ctrl_up()
                return event  # Pass through — Control is a shared modifier

            # Control+Escape for toggle
            if (
                event_type == Quartz.kCGEventKeyDown
                and keycode == KEYCODE_ESCAPE
                and (flags & Quartz.kCGEventFlagMaskControl)
            ):
                self._on_toggle()
                return None  # Suppress

            # Any other key press while waiting for PTT cancels it
            if (
                event_type == Quartz.kCGEventKeyDown
                and self._start_timer is not None
            ):
                self._cancel_ptt_start()

            return event

        if mode == HOTKEY_DICTATION:
            if keycode == KEYCODE_DICTATION:
                if event_type == Quartz.kCGEventKeyDown:
                    self._on_f5_down()
                elif event_type == Quartz.kCGEventKeyUp:
                    self._on_f5_up()
                return None  # Suppress F5 to block macOS dictation
            return event

        return event

    # --- Control-mode handlers ---

    def _on_ctrl_down(self):
        if self._ctrl_held:
            return
        self._ctrl_held = True
        # Ignore Ctrl while already in toggle-mode recording or transcribing
        if self.recording or self.transcribing:
            return
        # Schedule PTT start after hold delay
        if self._start_timer:
            self._start_timer.cancel()
        self._start_timer = threading.Timer(HOLD_DELAY, self._confirm_ptt_start)
        self._start_timer.daemon = True
        self._start_timer.start()

    def _confirm_ptt_start(self):
        self._start_timer = None
        if not self._ctrl_held:
            return
        if self.recording or self.transcribing:
            return
        self.toggle_active = False
        self.start_recording()

    def _cancel_ptt_start(self):
        if self._start_timer:
            self._start_timer.cancel()
            self._start_timer = None

    def _on_ctrl_up(self):
        if not self._ctrl_held:
            return
        self._ctrl_held = False
        # Cancel any pending start — hold was too short to count as PTT
        if self._start_timer:
            self._cancel_ptt_start()
            return
        # If we were PTT-recording, stop on release
        if self.recording and not self.toggle_active:
            self._handle_stop()
        # If toggle_active, ignore Ctrl release (user released after Ctrl+`)

    def _on_toggle(self):
        # Ctrl+Escape pressed: toggle recording regardless of PTT state
        self._cancel_ptt_start()
        if self.transcribing:
            return
        if self.recording:
            # Stop any active recording (PTT or toggle)
            self.toggle_active = False
            self._handle_stop()
        else:
            self.toggle_active = True
            self.start_recording()

    # --- F5-mode handlers (unchanged legacy behavior) ---

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
            self._stop_timer = threading.Timer(
                DOUBLE_TAP_WINDOW, self._delayed_stop
            )
            self._stop_timer.daemon = True
            self._stop_timer.start()

    def _delayed_stop(self):
        self._stop_timer = None
        if self.recording and not self.toggle_active:
            self._handle_stop()

    # --- Run loop ---

    def _request_microphone(self):
        """Proactively request mic access so macOS shows the permission prompt
        attributed to LokaVox.app and registers it under System Settings >
        Privacy & Security > Microphone. Without this, the spawned sox
        subprocess's mic request is silently denied on modern macOS (no prompt,
        silent capture). Requires NSMicrophoneUsageDescription in Info.plist."""
        try:
            import AVFoundation
            audio = AVFoundation.AVMediaTypeAudio
            status = AVFoundation.AVCaptureDevice.authorizationStatusForMediaType_(audio)
            # 0=notDetermined 1=restricted 2=denied 3=authorized
            if status == 0:
                AVFoundation.AVCaptureDevice.requestAccessForMediaType_completionHandler_(
                    audio, lambda granted: None
                )
        except Exception:
            pass

    def _prompt_for_accessibility(self):
        """The event tap failed → Accessibility permission is missing. A
        Finder-launched app has no console, so instead of exiting invisibly we
        show an alert with a shortcut straight to the Settings pane."""
        print("Failed to create event tap — Accessibility permission missing.")
        try:
            from AppKit import NSAlert, NSWorkspace
            from Foundation import NSURL
            NSApp.activateIgnoringOtherApps_(True)
            alert = NSAlert.alloc().init()
            alert.setMessageText_("LokaVox needs Accessibility permission")
            alert.setInformativeText_(
                "LokaVox uses Accessibility to capture your dictation hotkey "
                "and paste transcribed text.\n\n"
                "Enable LokaVox under System Settings → Privacy & Security "
                "→ Accessibility, then launch LokaVox again."
            )
            alert.addButtonWithTitle_("Open Accessibility Settings")
            alert.addButtonWithTitle_("Quit")
            if alert.runModal() == 1000:  # NSAlertFirstButtonReturn
                url = NSURL.URLWithString_(
                    "x-apple.systempreferences:com.apple.preference."
                    "security?Privacy_Accessibility"
                )
                NSWorkspace.sharedWorkspace().openURL_(url)
        except Exception:
            pass

    def run(self):
        self.preflight()

        print("LokaVox ready.")
        if settings.hotkey == HOTKEY_CONTROL:
            print("  Hold Control → hold-to-talk (250ms before recording starts)")
            print("  Control + Escape → toggle recording on/off")
        else:
            print("  Hold F5 (dictation key) → hold-to-talk")
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
        self._request_microphone()

        # CGEventTap — intercepts keyboard events. FlagsChanged is required
        # for Control-mode modifier detection; KeyDown/KeyUp for F5 and for
        # Control+Escape / cancel-on-other-key.
        mask = (
            Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventKeyUp)
            | Quartz.CGEventMaskBit(Quartz.kCGEventFlagsChanged)
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
            self._prompt_for_accessibility()
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
