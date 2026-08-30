#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${MAC_DICTATION_APP_DIR:-$HOME/Applications/MacDictationAgent.app}"
BUNDLE_ID="${MAC_DICTATION_BUNDLE_ID:-com.markschroedr.mac-dictation}"
VERSION="$(tr -d '[:space:]' < "$SOURCE_ROOT/VERSION")"

for dependency in swift iconutil codesign strip; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "missing required command: $dependency" >&2
    exit 1
  fi
done

if [[ -z "$VERSION" ]]; then
  echo "VERSION must not be empty" >&2
  exit 1
fi

STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mac-dictation-app.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGED_APP="$STAGING_ROOT/MacDictationAgent.app"
APP_BIN="$STAGED_APP/Contents/MacOS/MacDictationAgent"
APP_HELPER="$STAGED_APP/Contents/Helpers/FluidDictationService"
APP_ICON="$STAGED_APP/Contents/Resources/AppIcon.icns"
ICONSET="$STAGING_ROOT/AppIcon.iconset"
BUILD_ROOT="${MAC_DICTATION_BUILD_ROOT:-${TMPDIR:-/tmp}/mac-dictation-agent-swift-build}"

export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/swift-module-cache"

mkdir -p \
  "$STAGED_APP/Contents/MacOS" \
  "$STAGED_APP/Contents/Helpers" \
  "$STAGED_APP/Contents/Resources"

swift build \
  -c release \
  --disable-sandbox \
  --package-path "$SOURCE_ROOT/swift-agent" \
  --scratch-path "$BUILD_ROOT"
cp "$BUILD_ROOT/release/MacDictationAgent" "$APP_BIN"
cp "$BUILD_ROOT/release/FluidDictationService" "$APP_HELPER"
chmod +x "$APP_BIN" "$APP_HELPER"
strip -S "$APP_BIN" "$APP_HELPER"
swift "$SOURCE_ROOT/scripts/create_app_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP_ICON"

cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>MacDictationAgent</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Mac Dictation Agent</string>
  <key>CFBundleDisplayName</key>
  <string>Mac Dictation Agent</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Mac Dictation Agent records audio only when you start dictation or continuous transcription.</string>
</dict>
</plist>
PLIST

xattr -cr "$STAGED_APP" 2>/dev/null || true
codesign \
  --force \
  --sign - \
  --identifier "$BUNDLE_ID.fluid-asr" \
  "$APP_HELPER" >/dev/null
codesign \
  --force \
  --sign - \
  --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" \
  "$STAGED_APP" >/dev/null

mkdir -p "$(dirname "$APP_DIR")"
rm -rf "$APP_DIR"
mv "$STAGED_APP" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "built app bundle: $APP_DIR"
