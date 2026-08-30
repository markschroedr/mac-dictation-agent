#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER="$ROOT/asr_worker"
PORT="${MAC_DICTATION_ASR_PORT:-8931}"
DATA_ROOT="${MAC_DICTATION_DATA_ROOT:-$HOME/Library/Application Support/Mac Dictation Agent}"
MODEL_ROOT="${MAC_DICTATION_MODEL_ROOT:-$DATA_ROOT/models}"
TMP_DIR="$(mktemp -d)"
TEST_WAV="$TMP_DIR/test.wav"
SHORT_WAV="$TMP_DIR/short.wav"
trap 'kill "${pid:-}" 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT
bash "$ROOT/scripts/create_test_audio.sh" "$TEST_WAV"
bash "$ROOT/scripts/create_test_audio.sh" "$SHORT_WAV" 0.60

export MAC_DICTATION_MLX_CACHE="$MODEL_ROOT/mlx-cache"

cd "$WORKER"
uv sync >/dev/null
uv run uvicorn server:app --host 127.0.0.1 --port "$PORT" > "$ROOT/asr_worker/test-worker.log" 2>&1 &
pid=$!

for _ in {1..600}; do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

curl -fsS -X POST "http://127.0.0.1:$PORT/reset-session" \
  -H "Content-Type: application/json" \
  -d '{"session_id":"test"}' >/dev/null

curl -fsS -X POST "http://127.0.0.1:$PORT/transcribe-path" \
  -H "Content-Type: application/json" \
  -d "{\"session_id\":\"test\",\"chunk_index\":1,\"path\":\"$TEST_WAV\"}" \
  | uv run python -c '
import json
import sys

row = json.load(sys.stdin)
assert "error" not in row, row
assert row["duration_seconds"] > 0, row
assert row["recognize_seconds"] > 0, row
print(json.dumps({"text": row.get("text", ""), "speedup": row.get("speedup")}, ensure_ascii=False))
'

curl -fsS -X POST "http://127.0.0.1:$PORT/reset-session" \
  -H "Content-Type: application/json" \
  -d '{"session_id":"short-final"}' >/dev/null

curl -fsS -X POST "http://127.0.0.1:$PORT/transcribe-path" \
  -H "Content-Type: application/json" \
  -d "{\"session_id\":\"short-final\",\"chunk_index\":1,\"path\":\"$SHORT_WAV\",\"final\":true}" \
  | uv run python -c '
import json
import sys

row = json.load(sys.stdin)
assert "error" not in row, row
assert row["duration_seconds"] < 1.0, row
assert row["recognize_seconds"] > 0, row
print(json.dumps({"short_final_seconds": row["duration_seconds"]}))
'

curl -fsS -X POST "http://127.0.0.1:$PORT/transcribe-file" \
  -H "Content-Type: application/json" \
  -d "{\"paths\":[\"$TEST_WAV\",\"$TEST_WAV\"]}" \
  | uv run python -c '
import json
import sys

row = json.load(sys.stdin)
assert row["ok"] is True, row
assert row["backend"] == "parakeet-mlx", row
assert row["provider"] == "mlx", row
assert len(row["input_paths"]) == 2, row
assert row["text"].strip(), row
print(json.dumps({"file_api_inputs": len(row["input_paths"]), "file_api_text": row["text"]}, ensure_ascii=False))
'

curl -fsS -X POST "http://127.0.0.1:$PORT/v1/audio/transcriptions" \
  -F "file=@$TEST_WAV" \
  -F "model=local-parakeet-v3" \
  -F "response_format=json" \
  | uv run python -c '
import json
import sys

row = json.load(sys.stdin)
assert row["text"].strip(), row
print(json.dumps({"openai_compatible_text": row["text"]}, ensure_ascii=False))
'

curl -fsS -X POST "http://127.0.0.1:$PORT/shutdown" >/dev/null
status="$(curl -sS -o "$TMP_DIR/draining.json" -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/warmup")"
if [[ "$status" != "503" ]]; then
  echo "expected draining worker to reject warmup with 503, got $status" >&2
  cat "$TMP_DIR/draining.json" >&2
  exit 1
fi

for _ in {1..100}; do
  if ! kill -0 "$pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if kill -0 "$pid" 2>/dev/null; then
  echo "ASR worker did not exit after draining" >&2
  exit 1
fi
