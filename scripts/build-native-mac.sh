#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_DIR="$ROOT_DIR/client/macos-native"
CONFIGURATION="${CONFIGURATION:-release}"
ARCH="${ARCH:-$(uname -m)}"
APP_OUTPUT_DIR="$ROOT_DIR/dist-native"
APP_NAME="VibeCoding Plus"
BINARY_NAME="VibeCodingPlusNative"

case "$ARCH" in
  arm64|x86_64) ;;
  amd64) ARCH="x86_64" ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

# Map Configuration to swift build config (lowercase)
case "$CONFIGURATION" in
  Release|release) SPM_CONFIG="release" ;;
  Debug|debug)     SPM_CONFIG="debug" ;;
  *)               SPM_CONFIG="release" ;;
esac

mkdir -p "$APP_OUTPUT_DIR"

echo "==> swift build -c $SPM_CONFIG (arch: $ARCH)"
cd "$NATIVE_DIR"
swift build -c "$SPM_CONFIG" --arch "$ARCH"

BINARY_PATH="$NATIVE_DIR/.build/$SPM_CONFIG/$BINARY_NAME"
if [[ ! -f "$BINARY_PATH" ]]; then
  # SPM may place under .build/arm64-apple-macosx/release/
  BINARY_PATH=$(find "$NATIVE_DIR/.build" -name "$BINARY_NAME" -path "*/$SPM_CONFIG/*" -type f | head -1)
fi

APP_BUNDLE="$APP_OUTPUT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES"

cp "$BINARY_PATH" "$MACOS_DIR/$BINARY_NAME"
cp "$NATIVE_DIR/Resources/Info-spm.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# App icon
ICONUTIL_SRC="$NATIVE_DIR/.build/icon.iconset"
ICON_SRC="$NATIVE_DIR/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONUTIL_SRC"
cp "$ICON_SRC/AppIcon-16.png"    "$ICONUTIL_SRC/icon_16x16.png"
cp "$ICON_SRC/AppIcon-32.png"    "$ICONUTIL_SRC/icon_16x16@2x.png"
cp "$ICON_SRC/AppIcon-32.png"    "$ICONUTIL_SRC/icon_32x32.png"
cp "$ICON_SRC/AppIcon-64.png"    "$ICONUTIL_SRC/icon_32x32@2x.png"
cp "$ICON_SRC/AppIcon-128.png"   "$ICONUTIL_SRC/icon_128x128.png"
cp "$ICON_SRC/AppIcon-256.png"   "$ICONUTIL_SRC/icon_128x128@2x.png"
cp "$ICON_SRC/AppIcon-256.png"   "$ICONUTIL_SRC/icon_256x256.png"
cp "$ICON_SRC/AppIcon-512.png"   "$ICONUTIL_SRC/icon_256x256@2x.png"
cp "$ICON_SRC/AppIcon-512.png"   "$ICONUTIL_SRC/icon_512x512.png"
cp "$ICON_SRC/AppIcon-1024.png"  "$ICONUTIL_SRC/icon_512x512@2x.png"
iconutil -c icns "$ICONUTIL_SRC" -o "$RESOURCES/AppIcon.icns"
rm -rf "$ICONUTIL_SRC"

/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$CONTENTS/Info.plist"

codesign --force --deep --sign - "$APP_BUNDLE"
ditto -c -k --keepParent "$APP_BUNDLE" "$APP_OUTPUT_DIR/VibeCoding Plus-native-${SPM_CONFIG}-${ARCH}.zip"

echo "Native app built: $APP_BUNDLE"
echo "Native zip built: $APP_OUTPUT_DIR/VibeCoding Plus-native-${SPM_CONFIG}-${ARCH}.zip"
