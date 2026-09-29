"""Preserve unmixed capture inputs; independent of VAD and transcript compaction."""
from __future__ import annotations

import json
import subprocess
import time
import uuid
from datetime import UTC, datetime
from pathlib import Path


class SourceTracks:
    def __init__(self, root: Path, sample_rate: int) -> None:
        self.root = root / "storage" / "source_tracks" / (
            datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
        )
        self.root.mkdir(parents=True)
        self.sample_rate = sample_rate
        self.streams: dict[str, tuple[subprocess.Popen, object]] = {}

    def write(self, source: str, pcm: bytes) -> None:
        if not pcm:
            return
        if source not in self.streams:
            folder = self.root / source
            folder.mkdir()
            # Arrival time is not a hardware timestamp. Retain it as an alignment
            # hint, not a claim of sample-exact synchronization between devices.
            (folder / "capture.json").write_text(json.dumps({
                "source": source, "sample_rate": self.sample_rate, "channels": 1,
                "first_received_at": datetime.now(UTC).isoformat(),
                "first_received_monotonic": time.monotonic(),
                "timing": "arrival-time; independent source clocks",
                "segment_seconds": 60,
            }, indent=2) + "\n")
            log = (folder / "encoder.log").open("wb")
            try:
                process = subprocess.Popen([
                    "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
                    "-f", "s16le", "-ar", str(self.sample_rate), "-ac", "1",
                    "-i", "pipe:0", "-c:a", "libopus", "-b:a", "48k",
                    "-f", "segment", "-segment_time", "60", "-reset_timestamps", "1",
                    str(folder / "%06d.opus"),
                ], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=log)
            except BaseException:
                log.close()
                raise
            self.streams[source] = (process, log)
        process, _ = self.streams[source]
        assert process.stdin is not None
        process.stdin.write(pcm)

    def close(self) -> None:
        errors = []
        for source, (process, log) in self.streams.items():
            try:
                assert process.stdin is not None
                process.stdin.close()
                if process.wait(timeout=30) != 0:
                    errors.append(source)
            except (OSError, subprocess.TimeoutExpired):
                process.kill()
                process.wait()
                errors.append(source)
            finally:
                log.close()
        if errors:
            raise RuntimeError(f"Source audio encoding failed: {', '.join(errors)}; see {self.root}")
