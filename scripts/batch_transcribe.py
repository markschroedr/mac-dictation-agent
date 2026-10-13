"""Transcribe files through the running Mac Dictation Agent's shared model."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import urllib.request


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("batch-output"))
    args = parser.parse_args()
    extensions = {".wav", ".mp3", ".m4a", ".mp4", ".webm", ".opus", ".ogg", ".flac", ".aac", ".aiff", ".aif", ".caf", ".mov"}
    files = sorted({file.resolve() for path in args.inputs for file in
                    (path.expanduser().rglob("*") if path.expanduser().is_dir() else [path.expanduser()])
                    if file.is_file() and file.suffix.lower() in extensions})
    if not files:
        parser.error("no audio files found")
    # Refuse result collisions rather than overwrite an earlier batch.
    args.output_dir.mkdir(parents=True, exist_ok=False)
    texts = args.output_dir / "transcripts"
    texts.mkdir()
    rows = []
    port = int(os.environ.get("MAC_DICTATION_API_PORT", "8767"))
    with (args.output_dir / "results.jsonl").open("w", encoding="utf-8") as log:
        for index, path in enumerate(files):
            request = urllib.request.Request(f"http://127.0.0.1:{port}/transcribe-file",
                data=json.dumps({"paths": [str(path)]}).encode(),
                headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(request, timeout=3600) as response:
                row = {**json.load(response), "source_path": str(path)}
            rows.append(row)
            log.write(json.dumps(row, ensure_ascii=False) + "\n")
            log.flush()
            (texts / f"{index:05d}_{path.stem}.txt").write_text(row["text"] + "\n", encoding="utf-8")
    (args.output_dir / "results.json").write_text(
        json.dumps({"file_count": len(rows), "rows": rows}, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Transcribed {len(rows)} files into {args.output_dir}")


if __name__ == "__main__":
    main()
