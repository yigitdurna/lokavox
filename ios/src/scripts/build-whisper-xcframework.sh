#!/usr/bin/env bash
# Build whisper.cpp as an XCFramework for LokaVox iOS.
#
# Why this script exists:
#   whisper.cpp removed official SwiftPM support in March 2025 (ggml-org#2869).
#   The supported integration is a locally-built XCFramework. We commit the
#   resulting binary to ios/src/Vendor/whisper.xcframework so day-to-day
#   development doesn't require re-running this script — run it only when
#   bumping WHISPER_TAG below.
#
# Requirements: cmake, Xcode 16+, bash 4+, git.
# Output: ios/src/Vendor/whisper.xcframework (iOS device + simulator slices).

set -euo pipefail

# -- Config --------------------------------------------------------------

WHISPER_TAG="v1.8.4"   # Pinned upstream tag. Bump + rebuild to pick up fixes.
WHISPER_REPO="https://github.com/ggml-org/whisper.cpp.git"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                 # ios/src
VENDOR_DIR="$SRC_DIR/Vendor"
OUTPUT_DIR="$VENDOR_DIR/whisper.xcframework"
WORK_DIR="$(mktemp -d -t lokavox-whisper-build.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> LokaVox whisper.cpp XCFramework builder"
echo "    tag:    $WHISPER_TAG"
echo "    work:   $WORK_DIR"
echo "    output: $OUTPUT_DIR"

# -- Clone pinned tag ----------------------------------------------------

echo "==> Cloning whisper.cpp @ $WHISPER_TAG"
git clone --depth 1 --branch "$WHISPER_TAG" "$WHISPER_REPO" "$WORK_DIR/whisper.cpp"

cd "$WORK_DIR/whisper.cpp"

# -- Build the XCFramework (upstream script) -----------------------------
#
# Upstream's build-xcframework.sh produces slices for iOS device, iOS sim,
# macOS, tvOS, and visionOS. We only need the two iOS slices, so we slim
# down afterwards.

if [[ ! -x "./build-xcframework.sh" ]]; then
    echo "error: build-xcframework.sh not found in whisper.cpp checkout."
    echo "       Check the WHISPER_TAG — upstream may have moved it."
    exit 1
fi

# Ask upstream to build with Metal enabled and the Metal library embedded
# (no runtime resource file copying required on our side).
export GGML_METAL=ON
export GGML_METAL_EMBED_LIBRARY=ON

echo "==> Running upstream build-xcframework.sh (this takes a few minutes)"
./build-xcframework.sh

UPSTREAM_XCF="$WORK_DIR/whisper.cpp/build-apple/whisper.xcframework"
if [[ ! -d "$UPSTREAM_XCF" ]]; then
    echo "error: expected upstream output at $UPSTREAM_XCF but it is missing."
    exit 1
fi

# -- Slim to iOS-only -----------------------------------------------------
#
# Re-pack the XCFramework from only the ios-arm64 and ios-arm64_x86_64-simulator
# slices. Falls back to the full upstream output if the expected slice names
# aren't present (upstream has changed the layout before).

echo "==> Slimming to iOS device + simulator slices"

DEVICE_SLICE=""
SIMULATOR_SLICE=""
while IFS= read -r slice; do
    case "$(basename "$slice")" in
        ios-arm64)                           DEVICE_SLICE="$slice" ;;
        ios-arm64_x86_64-simulator)          SIMULATOR_SLICE="$slice" ;;
        ios-arm64-simulator)                 SIMULATOR_SLICE="$slice" ;;
    esac
done < <(find "$UPSTREAM_XCF" -mindepth 1 -maxdepth 1 -type d)

rm -rf "$OUTPUT_DIR"
mkdir -p "$VENDOR_DIR"

if [[ -n "$DEVICE_SLICE" && -n "$SIMULATOR_SLICE" ]]; then
    DEVICE_FWK="$DEVICE_SLICE/whisper.framework"
    SIMULATOR_FWK="$SIMULATOR_SLICE/whisper.framework"
    if [[ ! -d "$DEVICE_FWK" || ! -d "$SIMULATOR_FWK" ]]; then
        echo "warning: slices missing whisper.framework; falling back to full upstream output."
        cp -R "$UPSTREAM_XCF" "$OUTPUT_DIR"
    else
        xcodebuild -create-xcframework \
            -framework "$DEVICE_FWK" \
            -framework "$SIMULATOR_FWK" \
            -output "$OUTPUT_DIR" >/dev/null
    fi
else
    echo "warning: could not identify iOS slices in upstream output; copying whole XCFramework."
    cp -R "$UPSTREAM_XCF" "$OUTPUT_DIR"
fi

# -- Done ----------------------------------------------------------------

echo "==> Built $OUTPUT_DIR"
echo "    Slices:"
for slice in "$OUTPUT_DIR"/*/; do
    sz=$(du -sh "$slice" | awk '{print $1}')
    printf "      %-40s %s\n" "$(basename "$slice")" "$sz"
done
echo
echo "Next steps:"
echo "  cd $SRC_DIR"
echo "  xcodegen generate"
echo "  open LokaVox.xcodeproj"
