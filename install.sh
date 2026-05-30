#!/bin/bash
set -euo pipefail

# ─── Detect project directory ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Variables ───────────────────────────────────────────────────────────────
APP_NAME="LokaVox"
APP_DIR="$HOME/Applications/LokaVox.app"
BUNDLE_ID="com.local.lokavox"
VENV_DIR="$HOME/.local/share/lokavox/venv"
MODEL_DIR="$HOME/.local/share/whisper"
MODEL_FILE="$MODEL_DIR/ggml-large-v3-turbo.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"

echo "==> Building $APP_NAME.app"
echo "    Project dir: $SCRIPT_DIR"

# ─── Homebrew dependencies (auto-install if missing) ─────────────────────────
if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew is required but not installed."
    echo "       Install it from https://brew.sh then re-run ./install.sh"
    exit 1
fi
missing=()
for dep in whisper-cpp sox; do
    brew list "$dep" &>/dev/null || missing+=("$dep")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "==> Installing Homebrew dependencies: ${missing[*]}"
    brew install "${missing[@]}"
else
    echo "    Homebrew dependencies OK (whisper-cpp, sox)"
fi

# ─── Build toolchain (clang from Xcode Command Line Tools) ───────────────────
if ! command -v clang &>/dev/null; then
    echo "ERROR: clang not found — install the Xcode Command Line Tools:"
    echo "       xcode-select --install"
    exit 1
fi

# ─── Create Python venv ─────────────────────────────────────────────────────
if [ ! -d "$VENV_DIR" ]; then
    echo "==> Creating Python venv at $VENV_DIR"
    mkdir -p "$(dirname "$VENV_DIR")"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/python3" -m pip install --upgrade pip
    "$VENV_DIR/bin/pip" install --only-binary=:all: \
        pyobjc-framework-Quartz pyobjc-framework-Cocoa pyobjc-framework-AVFoundation
else
    echo "    Venv already exists at $VENV_DIR"
fi

# ─── Download whisper model ─────────────────────────────────────────────────
if [ ! -f "$MODEL_FILE" ]; then
    echo "==> Downloading whisper model (~1.6GB) to $MODEL_FILE"
    mkdir -p "$MODEL_DIR"
    curl -L --progress-bar -o "$MODEL_FILE" "$MODEL_URL"
else
    echo "    Whisper model already present"
fi

# ─── Stop any running instance (so the rebuild + re-sign is clean) ───────────
if pgrep -f lokavox.py &>/dev/null; then
    echo "==> Stopping running LokaVox instance"
    pkill -f lokavox.py || true
    sleep 1
fi

# ─── Build app bundle ───────────────────────────────────────────────────────
echo "==> Building app bundle at $APP_DIR"

# Create directory structure
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy app icon
if [ -f "$SCRIPT_DIR/resources/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
    echo "    Copied AppIcon.icns"
else
    echo "    WARNING: $SCRIPT_DIR/resources/AppIcon.icns not found, skipping icon"
fi

# Generate Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LokaVox</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.lokavox</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>LokaVox</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>LokaVox records your voice to transcribe it locally into text.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>LokaVox pauses and resumes media playback while you dictate.</string>
</dict>
</plist>
PLIST
echo "    Generated Info.plist"

# Build native launcher (compiled Mach-O — NOT a shell script)
# WHY compiled: a shell-script main executable has no architecture. On Apple
# Silicon, LaunchServices then launches it via the universal interpreter as
# x86_64 and demands Rosetta. A Mach-O built for the host arch ONLY launches
# natively (no x86_64 slice = nothing for macOS to run under Rosetta).
# CRITICAL: the launcher posix_spawns python and waits — it does NOT exec/replace
# itself. The .app's signed main-exec process stays alive as python's parent, so
# Accessibility/Microphone granted to LokaVox.app extend to the python child.
LAUNCHER_TMP="$(mktemp -d)"
cat > "$LAUNCHER_TMP/launcher.c" << 'LAUNCHER'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>

extern char **environ;

int main(int argc, char *argv[]) {
    setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", 1);

    const char *home = getenv("HOME");
    if (!home) home = "";
    char python[4096];
    snprintf(python, sizeof(python),
             "%s/.local/share/lokavox/venv/bin/python3", home);

    char **a = malloc(sizeof(char *) * (argc + 3));
    int n = 0;
    a[n++] = python;
    a[n++] = SCRIPT_PATH;
    for (int i = 1; i < argc; i++) a[n++] = argv[i];
    a[n] = NULL;

    pid_t pid;
    if (posix_spawn(&pid, python, NULL, NULL, a, environ) != 0) {
        perror("posix_spawn");
        return 1;
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) { /* retry on EINTR */ }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
LAUNCHER
HOST_ARCH="$(uname -m)"
clang -arch "$HOST_ARCH" -O2 \
    -DSCRIPT_PATH="\"$SCRIPT_DIR/lokavox.py\"" \
    -o "$APP_DIR/Contents/MacOS/LokaVox" "$LAUNCHER_TMP/launcher.c"
rm -rf "$LAUNCHER_TMP"
chmod +x "$APP_DIR/Contents/MacOS/LokaVox"
echo "    Built native $HOST_ARCH launcher (Mach-O — no Rosetta, TCC safe)"

# ─── Codesign ───────────────────────────────────────────────────────────────
echo "==> Ad-hoc codesigning"
codesign --force --deep --sign - "$APP_DIR"

# ─── Verify the build ────────────────────────────────────────────────────────
LAUNCHER_BIN="$APP_DIR/Contents/MacOS/LokaVox"
if ! file "$LAUNCHER_BIN" | grep -q "Mach-O"; then
    echo "ERROR: launcher is not a native Mach-O binary — build failed."
    exit 1
fi
if ! codesign --verify --strict "$APP_DIR" 2>/dev/null; then
    echo "ERROR: codesign verification failed."
    exit 1
fi
echo "    Verified: native $HOST_ARCH Mach-O launcher, signature valid"

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo "==> $APP_NAME.app built at ~/Applications/"
echo ""
echo "    Next steps:"
echo "    1. Launch LokaVox.app from Finder — NOT from a terminal (macOS would"
echo "       attribute the permissions to the terminal instead of to LokaVox)."
echo "    2. Click Allow on the Microphone prompt that appears on first launch."
echo "    3. Grant Accessibility when asked (LokaVox shows an alert with a button"
echo "       to the right Settings pane), then relaunch from Finder."
echo "    4. Optional: enable 'Launch at Login' in Preferences (menu bar icon)."
echo ""
echo "    Note: re-running install.sh re-signs the app, which clears the macOS"
echo "    permission grants — you'll re-grant Microphone + Accessibility once after."
