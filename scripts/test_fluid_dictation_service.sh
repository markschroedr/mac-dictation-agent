#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE="${MAC_DICTATION_FLUID_SERVICE_BIN:-$ROOT/swift-agent/.build/release/FluidDictationService}"
APP="${MAC_DICTATION_APP_BIN:-$ROOT/swift-agent/.build/release/MacDictationAgent}"
MODEL_ROOT="${MAC_DICTATION_FLUID_MODEL_ROOT:-$HOME/Library/Application Support/Mac Dictation Agent/models/fluid-audio}"
LEGACY_MODEL_ROOT="$HOME/Library/Application Support/FluidAudio/Models"
TEST_ROOT="$(mktemp -d -t mac-dictation-fluid-test)"
AUDIO="${1:-$TEST_ROOT/test.wav}"
REQUESTS=""
RESPONSES=""

cleanup() {
  rm -rf "$TEST_ROOT"
  [[ -z "$REQUESTS" ]] || rm -f "$REQUESTS"
  [[ -z "$RESPONSES" ]] || rm -f "$RESPONSES"
}
trap cleanup EXIT

if [[ ! -x "$SERVICE" || ! -x "$APP" ]]; then
  echo "missing release binaries; run 'swift build -c release' in swift-agent" >&2
  exit 1
fi
if [[ $# -eq 0 ]]; then
  say -v Anna "Dies ist ein kurzer Test der lokalen Spracherkennung." -o "$TEST_ROOT/test.aiff"
  ffmpeg -hide_banner -loglevel error -y -i "$TEST_ROOT/test.aiff" -ac 1 -ar 16000 "$AUDIO"
fi
if [[ ! -f "$AUDIO" ]]; then
  echo "missing test audio: $AUDIO" >&2
  exit 1
fi
if [[ ! -d "$MODEL_ROOT/parakeet-tdt-0.6b-v3" && -d "$LEGACY_MODEL_ROOT/parakeet-tdt-0.6b-v3" ]]; then
  MODEL_ROOT="$LEGACY_MODEL_ROOT"
fi

SESSION_ID="fluid-test-$$"
REQUESTS="$(mktemp)"
RESPONSES="$(mktemp)"

jq -nc --arg id reset --arg session "$SESSION_ID" \
  '{id:$id,action:"resetSession",sessionID:$session,final:false}' >"$REQUESTS"
jq -nc --arg id warmup '{id:$id,action:"warmup",final:false}' >>"$REQUESTS"
jq -nc --arg id first --arg session "$SESSION_ID" --arg path "$AUDIO" \
  '{id:$id,action:"transcribe",sessionID:$session,chunkIndex:1,path:$path,final:true}' >>"$REQUESTS"
jq -nc --arg id retry --arg session "$SESSION_ID" --arg path "$AUDIO" \
  '{id:$id,action:"transcribe",sessionID:$session,chunkIndex:1,path:$path,final:true}' >>"$REQUESTS"
jq -nc --arg id shutdown '{id:$id,action:"shutdown",final:false}' >>"$REQUESTS"

MAC_DICTATION_FLUID_MODEL_ROOT="$MODEL_ROOT" "$SERVICE" <"$REQUESTS" >"$RESPONSES"

FIRST_TEXT="$(jq -r 'select(.id == "first") | .text // ""' "$RESPONSES")"
RETRY_TEXT="$(jq -r 'select(.id == "retry") | .text // ""' "$RESPONSES")"
[[ -n "$FIRST_TEXT" ]]
[[ "$FIRST_TEXT" == "$RETRY_TEXT" ]]

BRIDGE_TEXT="$({
  MAC_DICTATION_AGENT_ROOT="$ROOT" \
  MAC_DICTATION_DATA_ROOT="$ROOT/data" \
  MAC_DICTATION_FLUID_SERVICE_BIN="$SERVICE" \
  MAC_DICTATION_FLUID_MODEL_ROOT="$MODEL_ROOT" \
    "$APP" --dictation-transcribe-file "$AUDIO"
} | grep -v '^\[' | tail -n 1)"
[[ "$BRIDGE_TEXT" == "$FIRST_TEXT" ]]

echo "fluid dictation service passed"
echo "$FIRST_TEXT"
