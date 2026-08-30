#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 INPUT_AUDIO [RUNS]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE="${MAC_DICTATION_FLUID_SERVICE_BIN:-$ROOT/swift-agent/.build/release/FluidDictationService}"
MODEL_ROOT="${MAC_DICTATION_FLUID_MODEL_ROOT:-$HOME/Library/Application Support/Mac Dictation Agent/models/fluid-audio}"
LEGACY_MODEL_ROOT="$HOME/Library/Application Support/FluidAudio/Models"
AUDIO="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
RUNS="${2:-5}"
REQUESTS="$(mktemp "${TMPDIR:-/tmp}/mac-dictation-benchmark-requests.XXXXXX")"
RESPONSES="$(mktemp "${TMPDIR:-/tmp}/mac-dictation-benchmark-responses.XXXXXX")"

cleanup() {
  rm -f "$REQUESTS" "$RESPONSES"
}
trap cleanup EXIT

if [[ ! -x "$SERVICE" ]]; then
  echo "missing release service; run 'swift build -c release --package-path swift-agent'" >&2
  exit 1
fi
if [[ ! -f "$AUDIO" ]]; then
  echo "input audio does not exist: $AUDIO" >&2
  exit 1
fi
if ! [[ "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
  echo "runs must be a positive integer" >&2
  exit 2
fi
if [[ ! -d "$MODEL_ROOT/parakeet-tdt-0.6b-v3" && -d "$LEGACY_MODEL_ROOT/parakeet-tdt-0.6b-v3" ]]; then
  MODEL_ROOT="$LEGACY_MODEL_ROOT"
fi

jq -nc --arg id warmup '{id:$id,action:"warmup",final:false}' >"$REQUESTS"
for run in $(seq 1 "$RUNS"); do
  session="benchmark-$run-$$"
  jq -nc --arg id "reset-$run" --arg session "$session" \
    '{id:$id,action:"resetSession",sessionID:$session,final:false}' >>"$REQUESTS"
  jq -nc --arg id "run-$run" --arg session "$session" --arg path "$AUDIO" \
    '{id:$id,action:"transcribe",sessionID:$session,chunkIndex:1,path:$path,final:true}' >>"$REQUESTS"
done
jq -nc --arg id shutdown '{id:$id,action:"shutdown",final:false}' >>"$REQUESTS"

MAC_DICTATION_FLUID_MODEL_ROOT="$MODEL_ROOT" "$SERVICE" <"$REQUESTS" >"$RESPONSES"

jq -s --argjson expected "$RUNS" '
  [ .[] | select(.id | startswith("run-")) ] as $runs
  | if ($runs | length) != $expected then error("missing benchmark responses") else . end
  | {
      runs: ($runs | length),
      audio_seconds: ($runs[0].durationSeconds),
      median_recognize_seconds: ($runs | map(.recognizeSeconds) | sort | .[length / 2 | floor]),
      median_realtime_speedup: ($runs | map(.speedup) | sort | .[length / 2 | floor]),
      min_recognize_seconds: ($runs | map(.recognizeSeconds) | min),
      max_recognize_seconds: ($runs | map(.recognizeSeconds) | max),
      transcript: ($runs[0].text)
    }
' "$RESPONSES"
