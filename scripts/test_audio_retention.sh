#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/swift-agent/.build/release/MacDictationAgent"

if [[ ! -x "$BIN" ]]; then
  swift build -c release --package-path "$ROOT/swift-agent"
fi

"$BIN" --audio-retention-test
