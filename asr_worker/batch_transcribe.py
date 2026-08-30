from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import tempfile
import time
import wave
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

import mlx.core as mx
from parakeet_mlx import from_pretrained

from model_config import MODEL_NAME, mlx_cache_dir

AUDIO_EXTENSIONS = {".wav", ".mp3", ".m4a", ".mp4", ".webm", ".opus", ".ogg", ".flac", ".aac"}


def main() -> int:
    parser = argparse.ArgumentParser(description="Batch transcription with Parakeet v3 MLX BF16.")
    parser.add_argument("inputs", nargs="+", type=Path, help="Audio files or directories.")
    parser.add_argument("--output-dir", type=Path, default=Path("batch-output"))
    parser.add_argument("--chunk-seconds", type=float, default=120.0)
    parser.add_argument("--overlap-seconds", type=float, default=15.0)
    parser.add_argument("--preconvert-workers", type=int, default=4)
    parser.add_argument("--keep-wav", action="store_true")
    args = parser.parse_args()
    if args.overlap_seconds >= args.chunk_seconds:
        raise SystemExit("--overlap-seconds must be smaller than --chunk-seconds")

    files = discover_audio_files(args.inputs)
    if not files:
        raise SystemExit("no audio files found")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    wav_root = args.output_dir / "normalized-wav"
    wav_root.mkdir(parents=True, exist_ok=True)
    temp_dir = None if args.keep_wav else tempfile.TemporaryDirectory(prefix="mac-dictation-batch-")
    wav_base = wav_root if args.keep_wav else Path(temp_dir.name)

    started_total = time.perf_counter()
    converted = preconvert_files(files, wav_base, args.preconvert_workers)
    load_started = time.perf_counter()
    model = from_pretrained(MODEL_NAME, dtype=mx.bfloat16, cache_dir=mlx_cache_dir())
    load_seconds = time.perf_counter() - load_started

    rows = recognize_files(model, converted, args.chunk_seconds, args.overlap_seconds, args.keep_wav)

    total_audio = sum(float(row["audio_seconds"]) for row in rows)
    recognize_seconds = sum(float(row["recognize_seconds"]) for row in rows)
    total_seconds = time.perf_counter() - started_total
    result = {
        "model": MODEL_NAME,
        "backend": "mlx",
        "precision": "bf16",
        "chunk_seconds": args.chunk_seconds,
        "overlap_seconds": args.overlap_seconds,
        "file_count": len(rows),
        "total_audio_seconds": round(total_audio, 3),
        "model_load_seconds": round(load_seconds, 3),
        "total_wall_seconds": round(total_seconds, 3),
        "overall_rtf": round(total_seconds / total_audio, 4) if total_audio else None,
        "overall_speedup": round(total_audio / total_seconds, 2) if total_seconds else None,
        "recognize_seconds": round(recognize_seconds, 3),
        "recognize_speedup": round(total_audio / recognize_seconds, 2) if recognize_seconds else None,
        "rows": rows,
    }
    (args.output_dir / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    write_jsonl(args.output_dir / "results.jsonl", rows)
    write_texts(args.output_dir / "transcripts", rows)
    print_summary(result)

    if temp_dir is not None:
        temp_dir.cleanup()
    return 0


def recognize_files(
    model: Any,
    converted: list[dict[str, object]],
    chunk_seconds: float,
    overlap_seconds: float,
    keep_wav: bool,
) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for item in converted:
        wav_path = Path(str(item["wav_path"]))
        source_path = Path(str(item["source_path"]))
        audio_seconds = wav_duration_seconds(wav_path)
        started = time.perf_counter()
        result = model.transcribe(
            str(wav_path),
            dtype=mx.bfloat16,
            chunk_duration=chunk_seconds,
            overlap_duration=overlap_seconds,
        )
        recognize_seconds = time.perf_counter() - started
        text = str(getattr(result, "text", "") or "").strip()
        rows.append(
            {
                "source_path": str(source_path),
                "wav_path": str(wav_path) if keep_wav else "",
                "audio_seconds": round(audio_seconds, 3),
                "processed_audio_seconds": round(audio_seconds, 3),
                "preconvert_seconds": item["preconvert_seconds"],
                "recognize_seconds": round(recognize_seconds, 3),
                "segments": len(getattr(result, "sentences", []) or []),
                "chunks": 1,
                "chars": len(text),
                "text": text,
            }
        )
    return rows


def discover_audio_files(inputs: list[Path]) -> list[Path]:
    files: list[Path] = []
    for item in inputs:
        path = item.expanduser().resolve()
        if path.is_dir():
            files.extend(
                sorted(
                    child
                    for child in path.rglob("*")
                    if child.is_file() and child.suffix.lower() in AUDIO_EXTENSIONS
                )
            )
        elif path.is_file() and path.suffix.lower() in AUDIO_EXTENSIONS:
            files.append(path)
    return files


def preconvert_files(files: list[Path], wav_base: Path, workers: int) -> list[dict[str, object]]:
    wav_base.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, object] | None] = [None] * len(files)
    with ThreadPoolExecutor(max_workers=max(1, workers)) as executor:
        futures = {
            executor.submit(convert_one, source, wav_base / f"{index:05d}_{source.stem}.wav"): index
            for index, source in enumerate(files)
        }
        for future in as_completed(futures):
            rows[futures[future]] = future.result()
    return [row for row in rows if row is not None]


def convert_one(source: Path, output: Path) -> dict[str, object]:
    started = time.perf_counter()
    normalize_audio(source, output)
    return {
        "source_path": str(source),
        "wav_path": str(output),
        "preconvert_seconds": round(time.perf_counter() - started, 3),
    }


def normalize_audio(source: Path, output: Path) -> None:
    if source.suffix.lower() == ".wav":
        try:
            with wave.open(str(source), "rb") as handle:
                if handle.getnchannels() == 1 and handle.getframerate() == 16_000 and handle.getsampwidth() == 2:
                    shutil.copy2(source, output)
                    return
        except wave.Error:
            pass
    subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(output),
        ],
        check=True,
    )


def wav_duration_seconds(path: Path) -> float:
    with wave.open(str(path), "rb") as handle:
        return handle.getnframes() / handle.getframerate()


def write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def write_texts(output_dir: Path, rows: list[dict[str, object]]) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    for index, row in enumerate(rows):
        source = Path(str(row["source_path"]))
        target = output_dir / f"{index:05d}_{source.stem}.txt"
        target.write_text(str(row["text"]).strip() + "\n", encoding="utf-8")


def print_summary(result: dict[str, object]) -> None:
    print(
        json.dumps(
            {
                "model": result["model"],
                "backend": result["backend"],
                "precision": result["precision"],
                "file_count": result["file_count"],
                "total_audio_seconds": result["total_audio_seconds"],
                "model_load_seconds": result["model_load_seconds"],
                "total_wall_seconds": result["total_wall_seconds"],
                "overall_speedup": result["overall_speedup"],
                "recognize_speedup": result["recognize_speedup"],
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    raise SystemExit(main())
