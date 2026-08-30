#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RAW="$ROOT/assets/demo/raw/dictation-demo.webm"

mkdir -p "$ROOT/assets/demo/raw"
(
  cd "$ROOT/scripts/demo"
  uvx --from shot-scraper==1.10 shot-scraper video storyboard.yml \
    --browser chrome \
    --output "$RAW"
)

DEMO_START=0 DEMO_POSTER_AT=10.1 \
  bash "$ROOT/scripts/demo/render_demo.sh" "$RAW"
