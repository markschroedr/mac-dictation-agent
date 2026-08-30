#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_ROOT="${MAC_DICTATION_DATA_ROOT:-$HOME/Library/Application Support/Mac Dictation Agent}"
MODEL_ROOT="${MAC_DICTATION_MODEL_ROOT:-$DATA_ROOT/models}"
export MAC_DICTATION_MLX_CACHE="${MAC_DICTATION_MLX_CACHE:-$MODEL_ROOT/mlx-cache}"
uv run --project "$ROOT/asr_worker" --frozen python "$ROOT/asr_worker/batch_transcribe.py" "$@"
