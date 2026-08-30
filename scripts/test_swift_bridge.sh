#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/swift-agent/.build/release/MacDictationAgent"
DATA_ROOT="${MAC_DICTATION_DATA_ROOT:-$HOME/Library/Application Support/Mac Dictation Agent}"
MODEL_ROOT="${MAC_DICTATION_MODEL_ROOT:-$DATA_ROOT/models}"
TMP_DIR="$(mktemp -d)"
TEST_WAV="$TMP_DIR/test.wav"
trap 'rm -rf "$TMP_DIR"' EXIT
bash "$ROOT/scripts/create_test_audio.sh" "$TEST_WAV"

if [[ ! -x "$BIN" ]]; then
  cd "$ROOT/swift-agent"
  swift build -c release
fi

export MAC_DICTATION_AGENT_ROOT="${MAC_DICTATION_AGENT_ROOT:-$ROOT}"
export MAC_DICTATION_DATA_ROOT="$DATA_ROOT"
export MAC_DICTATION_MODEL_ROOT="$MODEL_ROOT"
export MAC_DICTATION_ASR_PORT="${MAC_DICTATION_ASR_PORT:-8933}"
export MAC_DICTATION_MLX_CACHE="$MODEL_ROOT/mlx-cache"

"$BIN" --transcribe-file "$TEST_WAV"
