#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 OUTPUT_WAV [MAX_SECONDS]" >&2
  exit 2
fi

OUTPUT_WAV="$1"
MAX_SECONDS="${2:-}"
TEMP_AIFF="${OUTPUT_WAV%.wav}.aiff"
trap 'rm -f "$TEMP_AIFF"' EXIT

say "This is a local speech recognition test for Mac Dictation." -o "$TEMP_AIFF"

arguments=(-hide_banner -loglevel error -y -i "$TEMP_AIFF")
if [[ -n "$MAX_SECONDS" ]]; then
  arguments+=(-t "$MAX_SECONDS")
fi
ffmpeg "${arguments[@]}" -ac 1 -ar 16000 -c:a pcm_s16le "$OUTPUT_WAV"
