from __future__ import annotations

import hashlib
import subprocess
from pathlib import Path


def encode_pcm_to_opus(
    *,
    input_path: Path,
    output_path: Path,
    sample_rate_hz: int,
    channels: int,
    bitrate: str,
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "s16le",
        "-ar",
        str(sample_rate_hz),
        "-ac",
        str(channels),
        "-i",
        str(input_path),
        "-c:a",
        "libopus",
        "-b:a",
        bitrate,
        "-application",
        "voip",
        str(output_path),
    ]
    subprocess.run(cmd, check=True)


def decode_audio_to_wav(
    *,
    input_path: Path,
    output_path: Path,
    sample_rate_hz: int,
    channels: int = 1,
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(input_path),
        "-ar",
        str(sample_rate_hz),
        "-ac",
        str(channels),
        "-c:a",
        "pcm_s16le",
        str(output_path),
    ]
    subprocess.run(cmd, check=True)


def reencode_audio_to_opus(
    *,
    input_path: Path,
    output_path: Path,
    bitrate: str,
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(input_path),
        "-c:a",
        "libopus",
        "-b:a",
        bitrate,
        "-application",
        "voip",
        str(output_path),
    ]
    subprocess.run(cmd, check=True)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
