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

# ─── Check brew dependencies ────────────────────────────────────────────────
missing=()
for dep in whisper-cpp sox; do
    if ! brew list "$dep" &>/dev/null; then
        missing+=("$dep")
    fi
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing brew dependencies: ${missing[*]}"
    echo "       Run: brew install ${missing[*]}"
    exit 1
fi
echo "    Brew dependencies OK (whisper-cpp, sox)"

# ─── Create Python venv ─────────────────────────────────────────────────────
if [ ! -d "$VENV_DIR" ]; then
    echo "==> Creating Python venv at $VENV_DIR"
    mkdir -p "$(dirname "$VENV_DIR")"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install pyobjc-framework-Quartz pyobjc-framework-Cocoa
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
</dict>
</plist>
PLIST
echo "    Generated Info.plist"

# Generate shell wrapper
# CRITICAL: Do NOT use exec — it breaks macOS TCC permissions.
# The shell process must stay as parent so the .app's Accessibility
# and Microphone permissions extend to the Python child process.
cat > "$APP_DIR/Contents/MacOS/LokaVox" << WRAPPER
#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
"\$HOME/.local/share/lokavox/venv/bin/python3" "$SCRIPT_DIR/lokavox.py" "\$@"
WRAPPER
chmod +x "$APP_DIR/Contents/MacOS/LokaVox"
echo "    Generated shell wrapper (no exec — TCC safe)"

# ─── Codesign ───────────────────────────────────────────────────────────────
echo "==> Ad-hoc codesigning"
codesign --force --deep --sign - "$APP_DIR"

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo "==> $APP_NAME.app built at ~/Applications/"
echo ""
echo "    Next steps:"
echo "    1. Grant Accessibility permission:  System Settings > Privacy & Security > Accessibility > LokaVox.app"
echo "    2. Grant Microphone permission:     System Settings > Privacy & Security > Microphone > LokaVox.app"
echo "    3. Add to Login Items if desired:   System Settings > General > Login Items > +"
echo ""
echo "    Note: Re-codesigning invalidates permissions — you'll need to re-grant after."
