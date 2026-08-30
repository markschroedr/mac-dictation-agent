from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
import tempfile

from .config import AppPaths, CaptureConfig


@dataclass(slots=True)
class SegmentEvent:
    started_at: datetime
    ended_at: datetime
    duration_ms: int
    pcm_path: Path


class ActiveSegment:
    def __init__(self, paths: AppPaths, cfg: CaptureConfig, started_at: datetime) -> None:
        self.cfg = cfg
        self.started_at = started_at
        self.last_voice_at = started_at
        self.frames = 0
        tmp_handle = tempfile.NamedTemporaryFile(
            dir=paths.tmp_root,
            prefix="segment-",
            suffix=".pcm",
            delete=False,
        )
        self.path = Path(tmp_handle.name)
        self._handle = tmp_handle

    def write(self, frame: bytes) -> None:
        self._handle.write(frame)
        self.frames += 1

    def mark_voice(self, when: datetime) -> None:
        self.last_voice_at = when

    def close(self) -> None:
        self._handle.flush()
        self._handle.close()


class VadSegmenter:
    def __init__(self, cfg: CaptureConfig, paths: AppPaths, vad: object) -> None:
        self.cfg = cfg
        self.paths = paths
        self.vad = vad
        self.preroll: deque[tuple[bytes, datetime]] = deque(maxlen=cfg.preroll_frames)
        self.active: ActiveSegment | None = None
        self.silence_frames = 0

    def process_frame(self, frame: bytes, timestamp: datetime) -> SegmentEvent | None:
        is_speech = self.vad.is_speech(frame, self.cfg.sample_rate_hz)
        self.preroll.append((frame, timestamp))

        if self.active is None:
            if not is_speech:
                return None
            start_time = self.preroll[0][1] if self.preroll else timestamp
            self.active = ActiveSegment(self.paths, self.cfg, start_time)
            for buffered_frame, _ in self.preroll:
                self.active.write(buffered_frame)
            self.active.mark_voice(timestamp)
            self.silence_frames = 0
            return None

        self.active.write(frame)
        if is_speech:
            self.active.mark_voice(timestamp)
            self.silence_frames = 0
            return None

        self.silence_frames += 1
        if self.silence_frames < self.cfg.hangover_frames:
            return None

        segment = self.active
        self.active = None
        self.silence_frames = 0
        segment.close()
        if segment.frames < self.cfg.min_segment_frames:
            segment.path.unlink(missing_ok=True)
            return None

        ended_at = timestamp
        return SegmentEvent(
            started_at=segment.started_at.astimezone(UTC),
            ended_at=ended_at.astimezone(UTC),
            duration_ms=segment.frames * self.cfg.frame_ms,
            pcm_path=segment.path,
        )

    def flush(self, timestamp: datetime) -> SegmentEvent | None:
        if self.active is None:
            return None
        segment = self.active
        self.active = None
        segment.close()
        if segment.frames < self.cfg.min_segment_frames:
            segment.path.unlink(missing_ok=True)
            return None
        return SegmentEvent(
            started_at=segment.started_at.astimezone(UTC),
            ended_at=timestamp.astimezone(UTC),
            duration_ms=segment.frames * self.cfg.frame_ms,
            pcm_path=segment.path,
        )
