#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-quick}"
PORT="${MAC_DICTATION_ASR_PORT:-8931}"
DATA_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mac-dictation-permanent-asr-test.XXXXXX")"
APP_DATA_ROOT="${MAC_DICTATION_DATA_ROOT:-$HOME/Library/Application Support/Mac Dictation Agent}"
MODEL_ROOT="${MAC_DICTATION_MODEL_ROOT:-$APP_DATA_ROOT/models}"
TEST_WAV="$DATA_ROOT/input.wav"
WORKER_LOG="$DATA_ROOT/asr-worker.log"

cleanup() {
  if [[ -n "${ASR_PID:-}" ]]; then
    kill "$ASR_PID" >/dev/null 2>&1 || true
    wait "$ASR_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$DATA_ROOT"
}
trap cleanup EXIT

bash "$ROOT/scripts/create_test_audio.sh" "$TEST_WAV"

mkdir -p "$DATA_ROOT/storage/audio" "$DATA_ROOT/storage/manifests"
cp "$TEST_WAV" "$DATA_ROOT/storage/audio/input.wav"

python3 - "$DATA_ROOT" <<'PY'
from __future__ import annotations

import hashlib
import json
import sys
import wave
from datetime import UTC, datetime, timedelta
from pathlib import Path

root = Path(sys.argv[1])
audio = root / "storage/audio/input.wav"
with wave.open(str(audio), "rb") as handle:
    duration = handle.getnframes() / handle.getframerate()
started = datetime(2026, 1, 1, 12, 0, tzinfo=UTC)
ended = started + timedelta(seconds=duration)
row = {
    "segment_id": "test-segment-1",
    "started_at": started.isoformat(),
    "ended_at": ended.isoformat(),
    "duration_ms": int(duration * 1000),
    "sample_rate_hz": 16000,
    "path": "storage/audio/input.wav",
    "status": "captured",
    "sha256": hashlib.sha256(audio.read_bytes()).hexdigest(),
    "bytes": audio.stat().st_size,
}
(root / "storage/manifests/segments.jsonl").write_text(json.dumps(row) + "\n", encoding="utf-8")
PY

cd "$ROOT/asr_worker"
export PERMANENT_TRANSCRIBER_ROOT="$DATA_ROOT"
export MAC_DICTATION_ASR_PORT="$PORT"
export MAC_DICTATION_MLX_CACHE="$MODEL_ROOT/mlx-cache"
export HF_HOME="$MODEL_ROOT/huggingface"
export HUGGINGFACE_HUB_CACHE="$MODEL_ROOT/huggingface/hub"
export XDG_CACHE_HOME="$MODEL_ROOT/xdg-cache"

uv run uvicorn server:app --host 127.0.0.1 --port "$PORT" > "$WORKER_LOG" 2>&1 &
ASR_PID=$!

for _ in {1..300}; do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null

cd "$ROOT/vendor/permanent-transcriber"
export PERMANENT_TRANSCRIBER_ROOT="$DATA_ROOT"
export MAC_DICTATION_ASR_WORKER_DIR="$ROOT/asr_worker"
export MAC_DICTATION_ASR_PORT="$PORT"

uv run --frozen permanent-transcriber worker-once \
  --profile "$PROFILE" \
  --from-line 0 \
  --no-commit-state \
  --max-batches 1

python3 - "$DATA_ROOT/storage/manifests/transcripts.jsonl" "$PROFILE" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
profile = sys.argv[2]
rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(rows) == 1, rows
row = rows[0]
assert row["backend"] == "parakeet-mlx", row
assert row["provider"] == "mlx", row
assert row["mode"] == profile, row
assert row["text"].strip(), row
print(json.dumps({
    "mode": row["mode"],
    "backend": row["backend"],
    "provider": row["provider"],
    "chars": len(row["text"]),
    "text": row["text"][:120],
}, ensure_ascii=False))
PY
