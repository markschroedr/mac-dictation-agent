from __future__ import annotations

import logging
import os
import queue
import shutil
import threading
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from .config import AppPaths, CaptureConfig
from .ffmpeg_tools import encode_pcm_to_opus, sha256_file
from .manifest import append_jsonl


@dataclass(slots=True)
class FinalizedSegment:
    started_at: datetime
    ended_at: datetime
    duration_ms: int
    pcm_path: Path


class SegmentWriter:
    def __init__(self, paths: AppPaths, config: CaptureConfig, max_queue: int = 16) -> None:
        self.paths = paths
        self.config = config
        self.logger = logging.getLogger(__name__)
        self.queue: queue.Queue[FinalizedSegment | None] = queue.Queue(maxsize=max_queue)
        self._thread = threading.Thread(target=self._run, name="segment-writer", daemon=True)
        self._closed = False

    def start(self) -> None:
        self._thread.start()

    def submit(self, segment: FinalizedSegment) -> None:
        self.queue.put(segment)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self.queue.put(None)
        self._thread.join()

    def _run(self) -> None:
        while True:
            item = self.queue.get()
            if item is None:
                return
            try:
                self._persist(item)
            except Exception:
                self.logger.exception("failed to persist segment %s", item.pcm_path)
            finally:
                self.queue.task_done()

    def _persist(self, segment: FinalizedSegment) -> None:
        segment_id = uuid.uuid4().hex
        date_path = segment.started_at.astimezone(UTC).strftime("%Y/%m/%d/%H")
        started_label = segment.started_at.astimezone(UTC).strftime("%Y%m%dT%H%M%S.%f")[:-3] + "Z"
        ended_label = segment.ended_at.astimezone(UTC).strftime("%Y%m%dT%H%M%S.%f")[:-3] + "Z"
        final_dir = self.paths.audio_root / date_path
        final_dir.mkdir(parents=True, exist_ok=True)
        final_path = final_dir / f"{started_label}__{ended_label}.opus"
        temp_output = self.paths.tmp_root / f"{segment_id}.opus"

        encode_pcm_to_opus(
            input_path=segment.pcm_path,
            output_path=temp_output,
            sample_rate_hz=self.config.sample_rate_hz,
            channels=self.config.channels,
            bitrate=self.config.opus_bitrate,
        )
        shutil.move(str(temp_output), str(final_path))
        file_size = final_path.stat().st_size
        checksum = sha256_file(final_path)
        append_jsonl(
            self.paths.segments_manifest,
            {
                "segment_id": segment_id,
                "started_at": segment.started_at.astimezone(UTC).isoformat(),
                "ended_at": segment.ended_at.astimezone(UTC).isoformat(),
                "duration_ms": segment.duration_ms,
                "sample_rate_hz": self.config.sample_rate_hz,
                "opus_bitrate": self.config.opus_bitrate,
                "path": os.path.relpath(final_path, self.paths.root),
                "status": "captured",
                "sha256": checksum,
                "bytes": file_size,
            },
        )
        segment.pcm_path.unlink(missing_ok=True)
