#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/swift-agent/.build/release/MacDictationAgent"

if [[ ! -x "$BIN" ]]; then
  swift build -c release --package-path "$ROOT/swift-agent"
fi

export MAC_DICTATION_AGENT_ROOT="${MAC_DICTATION_AGENT_ROOT:-$ROOT}"
export MAC_DICTATION_DATA_ROOT="${MAC_DICTATION_DATA_ROOT:-$HOME/Library/Application Support/Mac Dictation Agent}"
export MAC_DICTATION_MODEL_ROOT="${MAC_DICTATION_MODEL_ROOT:-$MAC_DICTATION_DATA_ROOT/models}"

if [[ ! -x "$ROOT/vendor/permanent-transcriber/.venv/bin/permanent-transcriber" ]]; then
  uv sync --project "$ROOT/vendor/permanent-transcriber" --frozen
fi

exec "$BIN"
