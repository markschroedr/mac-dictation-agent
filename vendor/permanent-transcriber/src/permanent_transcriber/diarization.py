from __future__ import annotations

from dataclasses import asdict, dataclass
import math
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from typing import Any
import wave

from .config import AppPaths

MODEL_ID = "mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16"


@dataclass(slots=True)
class TimedText:
    start: float
    end: float
    text: str


@dataclass(slots=True)
class SpeakerSegment:
    start: float
    end: float
    speaker: str


class SortformerDiarizer:
    model_id: str | None = None

    def __init__(self, *, paths: AppPaths) -> None:
        self.paths = paths
        self._model: Any | None = None
        self.load_seconds: float | None = None

    def diarize(self, input_paths: list[Path], asr_segments: list[TimedText], fallback_text: str) -> dict[str, Any]:
        self.paths.tmp_root.mkdir(parents=True, exist_ok=True)
        tmp_dir = Path(tempfile.mkdtemp(prefix="sortformer-diarize-", dir=self.paths.tmp_root))
        try:
            wav_path = tmp_dir / "input.wav"
            concat_to_wav(input_paths, wav_path)
            audio_seconds = wav_duration_seconds(wav_path)

            started = time.perf_counter()
            result = self.model().generate(
                str(wav_path),
                threshold=0.5,
                min_duration=0.2,
                merge_gap=0.2,
                verbose=False,
            )
            elapsed = time.perf_counter() - started
            speaker_segments = normalize_speaker_segments(get_attr(result, "segments", default=[]))
            diarized_lines = assign_speakers_to_text(
                asr_segments=asr_segments,
                speaker_segments=speaker_segments,
                fallback_text=fallback_text,
                audio_seconds=audio_seconds,
            )
            speakers = sorted({segment.speaker for segment in speaker_segments})
            diarized_text = render_diarized_lines(diarized_lines)
            return {
                "model": self.model_id,
                "audio_seconds": round(audio_seconds, 3),
                "load_seconds": round(self.load_seconds or 0.0, 3),
                "elapsed_seconds": round(elapsed, 3),
                "rtf": round(elapsed / audio_seconds, 4) if audio_seconds > 0 else None,
                "speed_x_realtime": round(audio_seconds / elapsed, 2) if elapsed > 0 else math.inf,
                "speaker_count": len(speakers),
                "speakers": speakers,
                "speaker_segments": [asdict(segment) for segment in speaker_segments],
                "diarized_text": diarized_text,
                "diarized_lines": diarized_lines,
            }
        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)

    def model(self) -> Any:
        if self._model is None:
            from mlx_audio.vad import load

            started = time.perf_counter()
            self._model = load(MODEL_ID)
            self.model_id = MODEL_ID
            self.load_seconds = time.perf_counter() - started
        return self._model

def asr_segments_from_result(result: dict[str, Any]) -> list[TimedText]:
    rows = result.get("segments")
    if not isinstance(rows, list):
        return []
    segments: list[TimedText] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        text = str(row.get("text", "")).strip()
        if not text:
            continue
        try:
            start = float(row.get("start", 0.0))
            end = float(row.get("end", 0.0))
        except (TypeError, ValueError):
            continue
        if end <= start:
            continue
        segments.append(TimedText(start=start, end=end, text=text))
    return segments


def normalize_speaker_segments(raw_segments: Any) -> list[SpeakerSegment]:
    segments: list[SpeakerSegment] = []
    for item in raw_segments or []:
        start = get_attr(item, "start", "start_time", "start_sec", default=0.0)
        end = get_attr(item, "end", "end_time", "end_sec", default=0.0)
        speaker = get_attr(item, "speaker", "label", "speaker_id", default="SPEAKER_00")
        try:
            start_f = float(start)
            end_f = float(end)
        except (TypeError, ValueError):
            continue
        if end_f <= start_f:
            continue
        segments.append(SpeakerSegment(start=round(start_f, 3), end=round(end_f, 3), speaker=normalize_speaker_label(speaker)))
    return segments


def assign_speakers_to_text(
    *,
    asr_segments: list[TimedText],
    speaker_segments: list[SpeakerSegment],
    fallback_text: str,
    audio_seconds: float,
) -> list[dict[str, object]]:
    if not asr_segments and fallback_text.strip():
        asr_segments = [TimedText(start=0.0, end=audio_seconds, text=fallback_text.strip())]

    lines: list[dict[str, object]] = []
    for segment in asr_segments:
        speaker = best_speaker_for_interval(segment.start, segment.end, speaker_segments)
        if lines and lines[-1]["speaker"] == speaker:
            lines[-1]["end"] = round(segment.end, 3)
            lines[-1]["text"] = f"{lines[-1]['text']} {segment.text}".strip()
        else:
            lines.append(
                {
                    "speaker": speaker,
                    "start": round(segment.start, 3),
                    "end": round(segment.end, 3),
                    "text": segment.text,
                }
            )
    return lines


def best_speaker_for_interval(start: float, end: float, speaker_segments: list[SpeakerSegment]) -> str:
    overlap_by_speaker: dict[str, float] = {}
    for segment in speaker_segments:
        overlap = max(0.0, min(end, segment.end) - max(start, segment.start))
        if overlap > 0:
            overlap_by_speaker[segment.speaker] = overlap_by_speaker.get(segment.speaker, 0.0) + overlap
    if not overlap_by_speaker:
        return "Speaker ?"
    return max(overlap_by_speaker.items(), key=lambda item: item[1])[0]


def render_diarized_lines(lines: list[dict[str, object]]) -> str:
    return "\n".join(f"{line['speaker']}: {line['text']}" for line in lines).strip()


def normalize_speaker_label(value: Any) -> str:
    label = str(value).strip()
    if label.lower().startswith("speaker_"):
        suffix = label.split("_", 1)[1]
        return f"Speaker {suffix}"
    if label.isdigit():
        return f"Speaker {label}"
    return label or "Speaker ?"


def concat_to_wav(input_paths: list[Path], output_path: Path) -> None:
    if len(input_paths) == 1:
        decode_to_wav(input_paths[0], output_path)
        return
    list_path = output_path.parent / "inputs.ffconcat"
    list_path.write_text(
        "ffconcat version 1.0\n"
        + "".join(f"file '{escape_ffconcat_path(path)}'\n" for path in input_paths),
        encoding="utf-8",
    )
    subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-safe",
            "0",
            "-f",
            "concat",
            "-i",
            str(list_path),
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(output_path),
        ],
        check=True,
    )


def decode_to_wav(input_path: Path, output_path: Path) -> None:
    subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(input_path),
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(output_path),
        ],
        check=True,
    )


def escape_ffconcat_path(path: Path) -> str:
    return str(path).replace("'", "'\\''")


def wav_duration_seconds(path: Path) -> float:
    with wave.open(str(path), "rb") as handle:
        return handle.getnframes() / handle.getframerate()


def get_attr(obj: Any, *names: str, default: Any = None) -> Any:
    for name in names:
        if hasattr(obj, name):
            return getattr(obj, name)
    if isinstance(obj, dict):
        for name in names:
            if name in obj:
                return obj[name]
    return default
