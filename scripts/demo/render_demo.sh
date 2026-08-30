#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 INPUT.mov [OUTPUT_DIR]" >&2
  exit 1
fi

for dependency in ffmpeg ffprobe; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "missing required command: $dependency" >&2
    exit 1
  fi
done

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INPUT="$1"
OUTPUT_ROOT="${2:-$SOURCE_ROOT/assets/demo}"
START="${DEMO_START:-0}"
DURATION="${DEMO_DURATION:-}"
POSTER_AT="${DEMO_POSTER_AT:-2}"
PALETTE="$(mktemp "${TMPDIR:-/tmp}/mac-dictation-palette.XXXXXX.png")"

trap 'rm -f "$PALETTE"' EXIT

if [[ ! -f "$INPUT" ]]; then
  echo "input does not exist: $INPUT" >&2
  exit 1
fi

mkdir -p "$OUTPUT_ROOT"

TRIM=(-ss "$START")
if [[ -n "$DURATION" ]]; then
  TRIM+=(-t "$DURATION")
fi

VIDEO_FILTER="scale='min(1280,iw)':-2:flags=lanczos,fps=30"
GIF_FILTER="scale='min(960,iw)':-2:flags=lanczos,fps=15"

ffmpeg -hide_banner -loglevel error -y "${TRIM[@]}" -i "$INPUT" \
  -vf "$VIDEO_FILTER,format=yuv420p" \
  -c:v libx264 -preset slow -crf 18 -c:a aac -b:a 160k -movflags +faststart \
  "$OUTPUT_ROOT/dictation-demo.mp4"

ffmpeg -hide_banner -loglevel error -y "${TRIM[@]}" -i "$INPUT" \
  -vf "$VIDEO_FILTER" \
  -c:v libvpx-vp9 -b:v 0 -crf 28 -c:a libopus -b:a 96k \
  "$OUTPUT_ROOT/dictation-demo.webm"

ffmpeg -hide_banner -loglevel error -y "${TRIM[@]}" -i "$INPUT" \
  -vf "$GIF_FILTER,palettegen=stats_mode=diff" \
  -frames:v 1 -update 1 \
  "$PALETTE"

ffmpeg -hide_banner -loglevel error -y "${TRIM[@]}" -i "$INPUT" -i "$PALETTE" \
  -lavfi "$GIF_FILTER [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=3" \
  "$OUTPUT_ROOT/dictation-demo.gif"

ffmpeg -hide_banner -loglevel error -y -ss "$POSTER_AT" -i "$INPUT" -frames:v 1 -update 1 \
  -vf "scale='min(1280,iw)':-2:flags=lanczos" \
  "$OUTPUT_ROOT/dictation-demo-poster.png"

echo "demo exports: $OUTPUT_ROOT"
