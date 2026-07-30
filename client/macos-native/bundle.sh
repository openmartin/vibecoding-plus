#!/usr/bin/env bash
# bundle.sh — 将 swift build 产物组装为 macOS .app bundle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="${1:-release}"
APP_NAME="VibeCoding Plus"
BUNDLE_ID="com.mac20777.vibecodingplus"
BINARY_NAME="VibeCodingPlusNative"
OUTPUT_DIR="$SCRIPT_DIR/.build/artifacts"

echo "==> Building ($CONFIG)..."
swift build -c "$CONFIG"

BINARY_PATH="$SCRIPT_DIR/.build/$CONFIG/$BINARY_NAME"
if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Error: binary not found at $BINARY_PATH" >&2
  exit 1
fi

APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Assembling app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES"

# Binary
cp "$BINARY_PATH" "$MACOS_DIR/$BINARY_NAME"

# Info.plist
cp "$SCRIPT_DIR/Resources/Info-spm.plist" "$CONTENTS/Info.plist"

# PkgInfo
printf 'APPL????' > "$CONTENTS/PkgInfo"

# App icon (.icns)
ICONUTIL_SRC="$SCRIPT_DIR/.build/icon.iconset"
ICNS_OUT="$RESOURCES/AppIcon.icns"
mkdir -p "$ICONUTIL_SRC"

ICON_SRC="$SCRIPT_DIR/Resources/Assets.xcassets/AppIcon.appiconset"
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

iconutil -c icns "$ICONUTIL_SRC" -o "$ICNS_OUT"
rm -rf "$ICONUTIL_SRC"

# Inject icon reference into Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$CONTENTS/Info.plist"

# Ad-hoc codesign
echo "==> Codesigning (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "Done: $APP_BUNDLE"
echo "Run:  open \"$APP_BUNDLE\""
