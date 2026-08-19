#!/bin/bash
# Assembles Murmur.app from the SwiftPM build product.
#
# Xcode is not required: this builds with `swift build` and lays out the bundle
# by hand. A stable code-signing identity matters here — macOS keys the
# Microphone and Accessibility grants to the signature, so signing ad hoc would
# make you re-approve permissions after every rebuild.

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Murmur.app"
BUNDLE_ID="com.sikaihuang.murmur"

# Override with: MURMUR_SIGN_IDENTITY="Your Identity" ./scripts/build-app.sh
SIGN_IDENTITY="${MURMUR_SIGN_IDENTITY:-WindowDeck Dev}"

# The app itself builds with SwiftPM. xcodebuild cannot build it: FluidAudio's
# NemoTextProcessing.xcframework and Moonshine's Moonshine.xcframework both emit
# include/module.modulemap, and Xcode rejects the collision.
#
# SwiftPM in turn cannot compile MLX's Metal kernels, so the metallib is built
# once from a helper package that depends on mlx-swift alone, and copied in.
echo "==> Building ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG" --product MurmurApp

BINARY="$(swift build -c "$CONFIG" --product MurmurApp --show-bin-path)/MurmurApp"
[ -f "$BINARY" ] || { echo "error: binary not found at $BINARY" >&2; exit 1; }

echo "==> Building MLX metallib (xcodebuild)"
METALLIB_PKG="$ROOT/tools/MetallibBuilder"
METALLIB_DD="$METALLIB_PKG/.build-xc"
MLX_BUNDLE="$METALLIB_DD/Build/Products/Debug/mlx-swift_Cmlx.bundle"

if [ ! -d "$MLX_BUNDLE" ]; then
    (cd "$METALLIB_PKG" && xcodebuild \
        -scheme MetallibBuilder \
        -configuration Debug \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$METALLIB_DD" \
        -skipPackagePluginValidation \
        -skipMacroValidation \
        build) > "$ROOT/.metallib.log" 2>&1 || {
            echo "    warning: metallib build failed; MLX models will not run." >&2
            tail -5 "$ROOT/.metallib.log" >&2
        }
else
    echo "    reusing cached metallib"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Murmur"

# Resource bundles must travel with the app, notably mlx-swift_Cmlx.bundle,
# which carries the compiled Metal library.
# Resource bundles that must travel with the app.
for bundle in "$(dirname "$BINARY")"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done
# The compiled Metal library, without which MLX models fail to load.
if [ -d "$MLX_BUNDLE" ]; then
    cp -R "$MLX_BUNDLE" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Murmur</string>
    <key>CFBundleDisplayName</key><string>Murmur</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Murmur</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>

    <!-- Menu bar accessory: no Dock icon, never becomes the active app, so
         holding the hotkey cannot pull focus away from your text field. -->
    <key>LSUIElement</key><true/>

    <!-- Shown in the microphone permission prompt. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur captures audio only while you hold the dictation key, and transcribes it on-device.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Murmur transcribes your speech on-device to insert text into the app you are using.</string>
</dict>
</plist>
PLIST

echo "==> Signing as: $SIGN_IDENTITY"
ENTITLEMENTS="$ROOT/Murmur.entitlements"
if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    codesign --force --deep --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$APP"
else
    echo "    warning: identity '$SIGN_IDENTITY' not found; signing ad hoc."
    echo "    Permissions will need re-approval after each rebuild."
    codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
echo "==> Built $APP"
