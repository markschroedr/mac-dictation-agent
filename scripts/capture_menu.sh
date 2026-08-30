#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/assets/screenshots/menu.png}"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mac-dictation-menu-capture.XXXXXX")"
PREVIEW_PID=""

cleanup() {
  if [[ -n "$PREVIEW_PID" ]]; then
    kill -TERM "$PREVIEW_PID" 2>/dev/null || true
    wait "$PREVIEW_PID" 2>/dev/null || true
  fi
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

for dependency in swift ffmpeg screencapture osascript; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "missing required command: $dependency" >&2
    exit 1
  fi
done

swift build -c release --package-path "$ROOT/swift-agent"
osascript -e 'tell application "Finder" to activate'

env \
  MAC_DICTATION_AGENT_ROOT="$ROOT" \
  MAC_DICTATION_DATA_ROOT="$TEMP_ROOT/data" \
  MAC_DICTATION_MODEL_ROOT="$TEMP_ROOT/models" \
  MAC_DICTATION_FLUID_MODEL_ROOT="$TEMP_ROOT/models/fluid-audio" \
  MAC_DICTATION_FLUID_SERVICE_BIN="$ROOT/swift-agent/.build/release/FluidDictationService" \
  MAC_DICTATION_SUPERTONIC_TTS_SERVICE_BIN="$ROOT/supertonic_worker/.venv/bin/supertonic-tts-worker" \
  "$ROOT/swift-agent/.build/release/MacDictationAgent" --menu-preview \
  >"$TEMP_ROOT/preview.log" 2>&1 &
PREVIEW_PID="$!"

WINDOW_INFO=""
for _ in {1..40}; do
  WINDOW_INFO="$(swift "$ROOT/scripts/menu_window_info.swift" 2>/dev/null || true)"
  [[ -n "$WINDOW_INFO" ]] && break
  sleep 0.25
done

if [[ -z "$WINDOW_INFO" ]]; then
  echo "menu preview did not open" >&2
  exit 1
fi

read -r X Y WIDTH HEIGHT <<<"$WINDOW_INFO"
FULL_SCREEN="$TEMP_ROOT/full-screen.png"
screencapture -x "$FULL_SCREEN"
mkdir -p "$(dirname "$OUTPUT")"
ffmpeg -hide_banner -loglevel error -y \
  -i "$FULL_SCREEN" \
  -vf "crop=$WIDTH:$HEIGHT:$X:$Y" \
  "$OUTPUT"

echo "captured native menu: $OUTPUT"
