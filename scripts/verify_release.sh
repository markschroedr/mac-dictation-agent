#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$SOURCE_ROOT/VERSION")"
ARCHIVE="${1:-$SOURCE_ROOT/dist/Mac-Dictation-Agent-$VERSION-macOS-arm64.zip}"
CHECKSUM="$ARCHIVE.sha256"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mac-dictation-verify.XXXXXX")"

trap 'rm -rf "$TEST_ROOT"' EXIT

if [[ ! -f "$ARCHIVE" || ! -f "$CHECKSUM" ]]; then
  echo "release archive or checksum is missing" >&2
  exit 1
fi

(
  cd "$(dirname "$ARCHIVE")"
  shasum -a 256 -c "$(basename "$CHECKSUM")"
)
unzip -tq "$ARCHIVE"
ditto -x -k "$ARCHIVE" "$TEST_ROOT/package"

PACKAGE_ROOT="$TEST_ROOT/package/Mac-Dictation-Agent-$VERSION-macOS-arm64"
DATA_ROOT="$TEST_ROOT/data"
APP_DIR="$TEST_ROOT/Applications/MacDictationAgent.app"
PLIST="$TEST_ROOT/com.markschroedr.mac-dictation.release-test.plist"

for document in README.md LICENSE THIRD_PARTY_NOTICES.md CHANGELOG.md docs/PRIVACY.md THIRD_PARTY_LICENSES/FluidAudio-Apache-2.0.txt assets/mockups/readme-hero.png assets/screenshots/menu.png; do
  if [[ ! -f "$PACKAGE_ROOT/$document" ]]; then
    echo "release document is missing: $document" >&2
    exit 1
  fi
done

MAC_DICTATION_DATA_ROOT="$DATA_ROOT" \
MAC_DICTATION_INSTALL_ROOT="$DATA_ROOT/runtime" \
MAC_DICTATION_MODEL_ROOT="$DATA_ROOT/models" \
MAC_DICTATION_APP_DIR="$APP_DIR" \
MAC_DICTATION_PLIST="$PLIST" \
MAC_DICTATION_LAUNCH_AGENT_LABEL="com.markschroedr.mac-dictation.release-test" \
MAC_DICTATION_ASR_PORT="18766" \
MAC_DICTATION_PREBUILT_APP="$PACKAGE_ROOT/MacDictationAgent.app" \
MAC_DICTATION_ACTIVATE="0" \
MAC_DICTATION_WARM_MODELS="0" \
MAC_DICTATION_INSTALL_EXTRAS="0" \
  /bin/bash "$PACKAGE_ROOT/runtime/scripts/install_launch_agent.sh"

if [[ -d "$DATA_ROOT/runtime/asr_worker/.venv" ]]; then
  echo "core installation created an optional Python environment" >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_DIR"
plutil -lint "$APP_DIR/Contents/Info.plist" "$PLIST"
file "$APP_DIR/Contents/MacOS/MacDictationAgent" | grep -q 'arm64'
file "$APP_DIR/Contents/Helpers/FluidDictationService" | grep -q 'arm64'

MAC_DICTATION_DATA_ROOT="$DATA_ROOT" \
  "$APP_DIR/Contents/MacOS/MacDictationAgent" --audio-retention-test
"$APP_DIR/Contents/MacOS/MacDictationAgent" --hotkey-lock-test

if grep -R -I -E \
  --exclude='uv.lock' \
  --exclude='Package.resolved' \
  '/Users/markschroeder|Private Docs|private-mac|tailscale|github-private|id_ed25519' \
  "$PACKAGE_ROOT" >/dev/null; then
  echo "release contains a private path or host reference" >&2
  exit 1
fi

for executable in \
  "$APP_DIR/Contents/MacOS/MacDictationAgent" \
  "$APP_DIR/Contents/Helpers/FluidDictationService"; do
  if strings "$executable" | grep -E \
    '/Users/markschroeder|Private Docs|private-mac|tailscale|github-private|id_ed25519' \
    >/dev/null; then
    echo "release executable contains a private path or host reference: $executable" >&2
    exit 1
  fi
done

echo "release verification passed: $ARCHIVE"
