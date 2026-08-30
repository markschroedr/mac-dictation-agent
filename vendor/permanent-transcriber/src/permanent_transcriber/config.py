from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path


@dataclass(slots=True)
class CaptureConfig:
    sample_rate_hz: int = 16000
    channels: int = 1
    frame_ms: int = 30
    vad_aggressiveness: int = 1
    preroll_ms: int = 300
    hangover_ms: int = 900
    min_segment_ms: int = 800
    input_device: str | int | None = None
    queue_max_frames: int = 256
    opus_bitrate: str = "48k"
    digital_silence_timeout_seconds: float = 3.0

    @property
    def frame_bytes(self) -> int:
        samples_per_frame = self.sample_rate_hz * self.frame_ms // 1000
        return samples_per_frame * 2 * self.channels

    @property
    def preroll_frames(self) -> int:
        return max(1, self.preroll_ms // self.frame_ms)

    @property
    def hangover_frames(self) -> int:
        return max(1, self.hangover_ms // self.frame_ms)

    @property
    def min_segment_frames(self) -> int:
        return max(1, self.min_segment_ms // self.frame_ms)


@dataclass(slots=True)
class AppPaths:
    root: Path
    audio_root: Path
    audio_archive_root: Path
    manifests_root: Path
    logs_root: Path
    tmp_root: Path
    state_root: Path
    pid_file: Path
    worker_pid_file: Path
    segments_manifest: Path
    transcripts_manifest: Path
    diarized_transcripts_manifest: Path
    transcripts_text_log: Path
    transcripts_root: Path
    diarized_transcripts_root: Path
    audio_compactions_manifest: Path
    runtime_log: Path
    worker_log: Path
    capture_health_file: Path

    @classmethod
    def from_root(cls, root: Path) -> "AppPaths":
        storage_root = root / "storage"
        state_root = root / ".state"
        return cls(
            root=root,
            audio_root=storage_root / "audio",
            audio_archive_root=storage_root / "audio_archive",
            manifests_root=storage_root / "manifests",
            logs_root=storage_root / "logs",
            tmp_root=storage_root / "tmp",
            state_root=state_root,
            pid_file=state_root / "capture.pid",
            worker_pid_file=state_root / "worker.pid",
            segments_manifest=storage_root / "manifests" / "segments.jsonl",
            transcripts_manifest=storage_root / "manifests" / "transcripts.jsonl",
            diarized_transcripts_manifest=storage_root / "manifests" / "diarized_transcripts.jsonl",
            transcripts_text_log=storage_root / "manifests" / "transcript_text.log",
            transcripts_root=storage_root / "transcripts",
            diarized_transcripts_root=storage_root / "transcripts_diarized",
            audio_compactions_manifest=storage_root / "manifests" / "audio_compactions.jsonl",
            runtime_log=storage_root / "logs" / "capture.log",
            worker_log=storage_root / "logs" / "worker.log",
            capture_health_file=state_root / "capture-health.json",
        )

    def ensure(self) -> None:
        for path in (
            self.audio_root,
            self.manifests_root,
            self.logs_root,
            self.tmp_root,
            self.state_root,
        ):
            path.mkdir(parents=True, exist_ok=True)


def default_paths(project_root: Path | None = None) -> AppPaths:
    if project_root is None:
        env_root = os.environ.get("PERMANENT_TRANSCRIBER_ROOT")
        if env_root:
            project_root = Path(env_root).expanduser().resolve()
        else:
            cwd = Path.cwd().resolve()
            if (cwd / "pyproject.toml").exists():
                project_root = cwd
            else:
                project_root = Path(__file__).resolve().parents[2]
    return AppPaths.from_root(project_root)
