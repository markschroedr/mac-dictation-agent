#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT/supertonic_worker/.venv/bin/supertonic-tts-worker"
TEST_ROOT="$(mktemp -d -t mac-dictation-supertonic-test)"
PORT="${MAC_DICTATION_TTS_TEST_PORT:-18767}"
PID=""

cleanup() {
  if [[ -n "$PID" ]]; then
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

if [[ ! -x "$BINARY" ]]; then
  (cd "$ROOT/supertonic_worker" && uv sync --frozen)
fi

MAC_DICTATION_TTS_API_ENABLED=1 \
MAC_DICTATION_TTS_IDLE_SECONDS=1 \
MAC_DICTATION_SUPERTONIC_TTS_MODEL_ROOT="${MAC_DICTATION_SUPERTONIC_TTS_MODEL_ROOT:-$TEST_ROOT/models}" \
"$BINARY" --http --port "$PORT" \
  >"$TEST_ROOT/service.log" 2>"$TEST_ROOT/service.err.log" &
PID="$!"

service_ready=false
for _ in {1..30}; do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    service_ready=true
    break
  fi
  sleep 0.2
done
if [[ "$service_ready" != "true" ]]; then
  echo "Supertonic TTS service did not become healthy" >&2
  cat "$TEST_ROOT/service.err.log" >&2
  exit 1
fi

health="$(curl -fsS "http://127.0.0.1:$PORT/health")"
if [[ "$(jq -r '.loadedLanguage // empty' <<<"$health")" != "" ]]; then
  echo "health check loaded the model unexpectedly" >&2
  exit 1
fi

curl -fsS \
  -H 'Content-Type: application/json' \
  -d '{"model":"supertonic-3","language":"english","input":"Supertonic is running locally."}' \
  "http://127.0.0.1:$PORT/v1/audio/speech" \
  -o "$TEST_ROOT/speech.wav"
if [[ ! -s "$TEST_ROOT/speech.wav" ]]; then
  echo "speech request produced no audio" >&2
  exit 1
fi

sleep 1.5
health="$(curl -fsS "http://127.0.0.1:$PORT/health")"
if [[ "$(jq -r '.loadedLanguage // empty' <<<"$health")" != "" ]]; then
  echo "Supertonic model remained loaded after the idle deadline" >&2
  exit 1
fi

echo "Supertonic TTS HTTP lifecycle test passed"
