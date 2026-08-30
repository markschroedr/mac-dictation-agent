from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
import json
import os
from pathlib import Path
import time
from typing import Any


class DigitalSilenceError(RuntimeError):
    pass


@dataclass(slots=True)
class CaptureSignalMonitor:
    timeout_seconds: float
    started_at: float = field(default_factory=time.monotonic)
    frame_count: int = 0
    last_nonzero_at: float | None = None

    @property
    def has_signal(self) -> bool:
        return self.last_nonzero_at is not None

    def observe(self, frame: bytes, now: float | None = None) -> None:
        observed_at = time.monotonic() if now is None else now
        self.frame_count += 1
        if any(frame):
            self.last_nonzero_at = observed_at

    def check(self, now: float | None = None) -> None:
        checked_at = time.monotonic() if now is None else now
        last_signal = self.last_nonzero_at or self.started_at
        if checked_at - last_signal < self.timeout_seconds:
            return
        if self.frame_count == 0:
            raise DigitalSilenceError(
                f"input device delivered no audio frames for {self.timeout_seconds:.1f}s"
            )
        raise DigitalSilenceError(
            "input device delivered only digital silence; microphone permission or the CoreAudio stream is unavailable"
        )


def read_capture_health(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}
    return value if isinstance(value, dict) else {}


def write_capture_health(
    path: Path,
    *,
    status: str,
    pid: int,
    device: str | int | None,
    error: str | None = None,
) -> None:
    payload: dict[str, Any] = {
        "status": status,
        "pid": pid,
        "device": device,
        "updated_at": datetime.now(UTC).isoformat(),
    }
    if error:
        payload["error"] = error
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)
