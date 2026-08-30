#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${MAC_DICTATION_APP_BIN:-$ROOT/swift-agent/.build/release/MacDictationAgent}"
SERVICE="${MAC_DICTATION_FLUID_SERVICE_BIN:-$ROOT/swift-agent/.build/release/FluidDictationService}"
MODEL_ROOT="${MAC_DICTATION_FLUID_MODEL_ROOT:-$HOME/Library/Application Support/Mac Dictation Agent/models/fluid-audio}"
DURATION="${1:-22}"
OUTPUT="$(mktemp)"
trap 'rm -f "$OUTPUT"' EXIT

if [[ ! -x "$APP" || ! -x "$SERVICE" ]]; then
  echo "missing release binaries; run 'swift build -c release' in swift-agent" >&2
  exit 1
fi

env \
  MAC_DICTATION_AGENT_ROOT="$ROOT" \
  MAC_DICTATION_DATA_ROOT="$ROOT/data" \
  MAC_DICTATION_FLUID_SERVICE_BIN="$SERVICE" \
  MAC_DICTATION_FLUID_MODEL_ROOT="$MODEL_ROOT" \
  "$APP" --flow-test "$DURATION" | tee "$OUTPUT"

[[ "$(grep -c 'audio recorder queue started' "$OUTPUT")" -eq 1 ]]
grep -q 'audio segment finalized context=rotation' "$OUTPUT"
grep -q 'audio segment finalized context=stop' "$OUTPUT"
grep -q 'flow-test completion result=success' "$OUTPUT"
if grep -Eq 'dropped_buffers=[1-9][0-9]*|audio recorder enqueue failed|audio writer failed' "$OUTPUT"; then
  echo "continuous capture reported an audio loss or writer failure" >&2
  exit 1
fi

echo "continuous dictation chunking passed"
