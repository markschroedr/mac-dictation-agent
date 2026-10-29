from __future__ import annotations

from dataclasses import dataclass
import logging
import os
import signal
import shutil
import threading
import time
import uuid
from datetime import UTC, datetime
from pathlib import Path

from .asr_backends import AsrBackend, FluidAudioBackend
from .config import AppPaths
from .diarization import SortformerDiarizer, asr_segments_from_result
from .ffmpeg_tools import reencode_audio_to_opus, sha256_file
from .manifest import (
    append_jsonl, append_text, iter_jsonl, jsonl_position, load_json,
    read_jsonl_from_offset, write_json,
)
from .process_state import acquire_process_lock, hold_start_lock, read_live_pid, stop_process
from .source_transcripts import process_sessions, processing_status


@dataclass(slots=True)
class TranscriptionProfile:
    name: str
    status: str
    poll_seconds: float = 3.0
    batch_max_segments: int = 25
    batch_max_duration_ms: int = 90_000
    shutdown_timeout_seconds: float = 120.0
    compact_audio_after_transcribe: bool = False
    archive_audio_bitrate: str = "24k"
    diarize: bool = False


def profile_for_name(name: str) -> TranscriptionProfile:
    if name == "quick":
        return TranscriptionProfile(
            name="quick",
            status="provisional",
            poll_seconds=3.0,
            batch_max_segments=1,
            batch_max_duration_ms=30_000,
            shutdown_timeout_seconds=60.0,
        )
    if name == "relaxed":
        return TranscriptionProfile(
            name="relaxed",
            status="canonical",
            poll_seconds=3.0,
            batch_max_segments=500,
            batch_max_duration_ms=5 * 60 * 1000,
            shutdown_timeout_seconds=180.0,
            compact_audio_after_transcribe=True,
            archive_audio_bitrate="24k",
            diarize=True,
        )
    raise RuntimeError(f"unknown transcription profile: {name}")


class TranscriptionWorker:
    def __init__(
        self,
        *,
        paths: AppPaths,
        profile: str = "relaxed",
        poll_seconds: float | None = None,
        batch_max_segments: int | None = None,
        batch_max_duration_ms: int | None = None,
        diarize: bool | None = None,
    ) -> None:
        self.paths = paths
        self.profile = profile_for_name(profile)
        if poll_seconds is not None:
            self.profile.poll_seconds = poll_seconds
        if batch_max_segments is not None:
            self.profile.batch_max_segments = batch_max_segments
        if batch_max_duration_ms is not None:
            self.profile.batch_max_duration_ms = batch_max_duration_ms
        if diarize is not None:
            self.profile.diarize = diarize

        self.logger = logging.getLogger(__name__)
        self._stop_event = threading.Event()
        self._pending: list[dict[str, object]] = []
        self._pending_offsets: list[int] = []
        self._state: dict[str, object] = {"last_processed_line": 0}
        self._read_cursor = 0
        self._read_offset = 0
        self._state_loaded = False
        self._backend: AsrBackend | None = None
        self._diarizer: SortformerDiarizer | None = None
        self._failed_source_sessions: set[Path] = set()

    @property
    def state_file(self) -> Path:
        return self.paths.state_root / f"worker-{self.profile.name}.json"

    @property
    def pid_file(self) -> Path:
        return self.paths.state_root / f"worker-{self.profile.name}.pid"

    def run_forever(self) -> None:
        self.paths.ensure()
        acquire_process_lock(self.pid_file, f"{self.profile.name} worker")
        self._load_state()
        try:
            self._install_signal_handlers()
            self.logger.info("worker started profile=%s", self.profile.name)
            while not self._stop_event.is_set():
                processed = self._poll_and_process(flush_partial=False)
                if processed == 0:
                    if read_live_pid(self.paths.pid_file) is None and self._finished():
                        self.logger.info("no capture and no pending audio; exiting profile=%s", self.profile.name)
                        break
                    self._stop_event.wait(self.profile.poll_seconds)
        finally:
            self._drain_pending()
            self.logger.info("worker stopped profile=%s", self.profile.name)

    def run_once(
        self,
        *,
        max_batches: int | None = None,
        max_segments: int | None = None,
        from_line: int | None = None,
        commit_state: bool = True,
    ) -> int:
        self.paths.ensure()
        if from_line is not None:
            commit_state = False
            self._set_cursor(from_line)
            self._state = {"last_processed_line": from_line}
            self._state_loaded = True
        else:
            self._load_state(commit_state=commit_state)

        processed_total = 0
        batches = 0
        while True:
            processed = self._poll_and_process(
                max_segments=(max_segments - processed_total if max_segments is not None else None),
                commit_state=commit_state,
                reload_state=from_line is None,
            )
            processed_total += processed
            if processed == 0:
                break
            batches += 1
            if max_batches is not None and batches >= max_batches:
                break
            if max_segments is not None and processed_total >= max_segments:
                break
        return processed_total

    def stop(self) -> bool:
        timeout = float(
            os.environ.get(
                "PERMANENT_TRANSCRIBER_WORKER_STOP_TIMEOUT_SECONDS",
                str(self.profile.shutdown_timeout_seconds),
            )
        )
        return stop_process(self.pid_file, timeout_seconds=timeout)

    @staticmethod
    def read_pid(path: Path) -> int | None:
        return read_live_pid(path)

    def _poll_and_process(
        self,
        *,
        max_segments: int | None = None,
        commit_state: bool = True,
        reload_state: bool = True,
        flush_partial: bool = True,
    ) -> int:
        self.paths.ensure()
        if reload_state and not self._state_loaded:
            self._load_state(commit_state=commit_state)
        source_count = (process_sessions(self.paths, self.backend, self._failed_source_sessions)
                        if self.profile.name == "relaxed" else 0)
        pending_limit = self.profile.batch_max_segments
        if max_segments is not None:
            pending_limit = min(pending_limit, max_segments)
        next_rows, next_offsets = read_jsonl_from_offset(
            self.paths.segments_manifest, self._read_offset,
            max_rows=max(0, pending_limit - len(self._pending)),
        )
        if next_rows:
            self._pending.extend(next_rows)
            self._pending_offsets.extend(next_offsets)
            self._read_cursor += len(next_rows)
            self._read_offset = next_offsets[-1]
            self.logger.info("worker queued %s new segments profile=%s", len(next_rows), self.profile.name)

        if not self._pending:
            return source_count
        if not flush_partial and not self._batch_ready():
            return source_count

        processed_count = self._flush_batch()
        if commit_state:
            self._commit_processed(processed_count)
        del self._pending_offsets[:processed_count]
        return processed_count + source_count

    def _finished(self) -> bool:
        """Decide to exit under the start lock; keep holding it until this process exits."""
        self._drain_pending()
        lock = hold_start_lock(self.paths.state_root)
        # Start may have launched a capture, or a capture may have left new
        # audio, while this worker drained or waited for the lock.
        if (read_live_pid(self.paths.pid_file) is not None
                or processing_status(self.paths)[0]
                or read_jsonl_from_offset(self.paths.segments_manifest, self._read_offset, max_rows=1)[0]):
            os.close(lock)
            return False
        return True

    def _batch_ready(self) -> bool:
        if len(self._pending) >= self.profile.batch_max_segments:
            return True
        return sum(int(row.get("duration_ms", 0)) for row in self._pending) >= self.profile.batch_max_duration_ms

    def _drain_pending(self) -> None:
        while self._poll_and_process(flush_partial=True) > 0:
            pass

    def _flush_batch(self) -> int:
        if not self._pending:
            return 0
        batch: list[dict[str, object]] = []
        duration_ms = 0
        for row in self._pending:
            row_duration_ms = int(row.get("duration_ms", 0))
            if batch:
                if len(batch) >= self.profile.batch_max_segments:
                    break
                if duration_ms + row_duration_ms > self.profile.batch_max_duration_ms:
                    break
            batch.append(row)
            duration_ms += row_duration_ms

        segment_paths = self._resolve_audio_paths(batch)
        result = self.backend().transcribe_files(segment_paths)
        text = str(result.get("text", "")).strip()
        record = {
            "job_id": uuid.uuid4().hex,
            "created_at": datetime.now(UTC).isoformat(),
            "audio_started_at": batch[0]["started_at"],
            "audio_ended_at": batch[-1]["ended_at"],
            "segment_ids": [row["segment_id"] for row in batch],
            "segment_count": len(batch),
            "mode": self.profile.name,
            "status": self.profile.status,
            "backend": result["backend"],
            "model": result["model"],
            "provider": result["provider"],
            "audio_seconds": result["audio_seconds"],
            "elapsed_seconds": result["elapsed_seconds"],
            "rtf": result["rtf"],
            "lang": result.get("lang", ""),
            "text": text,
        }
        if "load_seconds" in result:
            record["load_seconds"] = result["load_seconds"]
        append_jsonl(self.paths.transcripts_manifest, record)
        if text:
            self._append_profile_text(batch=batch, record=record, text=text)
            self._maybe_write_diarized_transcript(
                batch=batch,
                record=record,
                result=result,
                text=text,
                segment_paths=segment_paths,
            )
        else:
            self.logger.warning(
                "transcribed batch produced empty text profile=%s segment_count=%s audio_seconds=%s",
                self.profile.name,
                len(batch),
                result["audio_seconds"],
            )
        self.logger.info(
            "transcribed batch profile=%s segment_count=%s audio_seconds=%s elapsed_seconds=%s rtf=%s",
            self.profile.name,
            len(batch),
            result["audio_seconds"],
            result["elapsed_seconds"],
            result["rtf"],
        )
        if self.profile.compact_audio_after_transcribe:
            self._compact_batch_audio(batch)
        if self._pending[: len(batch)] == batch:
            self._pending = self._pending[len(batch) :]
        return len(batch)

    def backend(self) -> AsrBackend:
        if self._backend is None:
            self._backend = FluidAudioBackend()
        return self._backend

    def _append_profile_text(
        self,
        *,
        batch: list[dict[str, object]],
        record: dict[str, object],
        text: str,
    ) -> None:
        started_at = datetime.fromisoformat(str(batch[0]["started_at"]))
        hour_path = (
            self.paths.transcripts_root
            / self.profile.name
            / f"{started_at:%Y}"
            / f"{started_at:%m}"
            / f"{started_at:%d}"
            / f"{started_at:%H}.md"
        )
        header = (
            f"\n\n## {record['audio_started_at']} -> {record['audio_ended_at']} "
            f"({record['segment_count']} segments, {record['audio_seconds']}s, "
            f"{record['backend']}, rtf={record['rtf']})\n\n"
        )
        append_text(hour_path, header + text + "\n")

    def _maybe_write_diarized_transcript(
        self,
        *,
        batch: list[dict[str, object]],
        record: dict[str, object],
        result: dict[str, object],
        text: str,
        segment_paths: list[Path],
    ) -> None:
        if not self.profile.diarize:
            return
        try:
            started = time.perf_counter()
            diarization = self.diarizer().diarize(
                input_paths=segment_paths,
                asr_segments=asr_segments_from_result(result),
                fallback_text=text,
            )
            diarized_text = str(diarization.get("diarized_text", "")).strip()
            if not diarized_text:
                self.logger.warning("diarization produced empty output job_id=%s", record["job_id"])
                return
            diarized_record = {
                "job_id": record["job_id"],
                "created_at": datetime.now(UTC).isoformat(),
                "transcript_created_at": record["created_at"],
                "audio_started_at": record["audio_started_at"],
                "audio_ended_at": record["audio_ended_at"],
                "segment_ids": record["segment_ids"],
                "segment_count": record["segment_count"],
                "mode": self.profile.name,
                "status": record["status"],
                "asr_backend": record["backend"],
                "asr_model": record["model"],
                "diarization_model": diarization.get("model"),
                "speaker_count": diarization.get("speaker_count"),
                "speakers": diarization.get("speakers", []),
                "audio_seconds": diarization.get("audio_seconds"),
                "diarization_elapsed_seconds": diarization.get("elapsed_seconds"),
                "diarization_rtf": diarization.get("rtf"),
                "diarization_speed_x_realtime": diarization.get("speed_x_realtime"),
                "diarization_chunk_seconds": diarization.get("chunk_seconds"),
                "diarization_chunk_count": diarization.get("chunk_count"),
                "diarization_memory_limit_bytes": diarization.get("memory_limit_bytes"),
                "diarization_peak_memory_bytes": diarization.get("peak_memory_bytes"),
                "total_elapsed_seconds": round(time.perf_counter() - started, 3),
                "diarized_lines": diarization.get("diarized_lines", []),
                "speaker_segments": diarization.get("speaker_segments", []),
                "text": diarized_text,
            }
            append_jsonl(self.paths.diarized_transcripts_manifest, diarized_record)
            self._append_diarized_profile_text(batch=batch, record=diarized_record, text=diarized_text)
            self.logger.info(
                "diarized batch profile=%s segment_count=%s speakers=%s elapsed_seconds=%s rtf=%s",
                self.profile.name,
                len(batch),
                diarized_record["speaker_count"],
                diarized_record["diarization_elapsed_seconds"],
                diarized_record["diarization_rtf"],
            )
        except Exception:
            self.logger.exception("diarization failed profile=%s job_id=%s", self.profile.name, record["job_id"])

    def _append_diarized_profile_text(
        self,
        *,
        batch: list[dict[str, object]],
        record: dict[str, object],
        text: str,
    ) -> None:
        started_at = datetime.fromisoformat(str(batch[0]["started_at"]))
        hour_path = (
            self.paths.diarized_transcripts_root
            / self.profile.name
            / f"{started_at:%Y}"
            / f"{started_at:%m}"
            / f"{started_at:%d}"
            / f"{started_at:%H}.md"
        )
        header = (
            f"\n\n## {record['audio_started_at']} -> {record['audio_ended_at']} "
            f"({record['segment_count']} segments, {record['audio_seconds']}s, "
            f"{record['asr_backend']} + {record['diarization_model']}, "
            f"speakers={record['speaker_count']}, rtf={record['diarization_rtf']})\n\n"
        )
        append_text(hour_path, header + text + "\n")

    def diarizer(self) -> SortformerDiarizer:
        if self._diarizer is None:
            self._diarizer = SortformerDiarizer(paths=self.paths)
        return self._diarizer

    def _compact_batch_audio(self, batch: list[dict[str, object]]) -> None:
        # New archives need no history lookup. Keep only this batch's existing archives.
        existing_paths = {str(row["path"]) for row in batch if self._archive_audio_path(row).exists()}
        compacted = self._load_compacted_audio(existing_paths)
        for row in batch:
            relative_path = str(row["path"])
            input_path = self.paths.root / relative_path
            archived_path = self._archive_audio_path(row)
            if not input_path.exists():
                if archived_path.exists():
                    continue
                self.logger.warning("cannot compact missing audio path=%s", input_path)
                continue
            current_sha = sha256_file(input_path)
            existing = compacted.get((relative_path, self.profile.archive_audio_bitrate))
            if existing and archived_path.exists() and sha256_file(archived_path) == existing:
                input_path.unlink(missing_ok=True)
                continue
            old_bytes = input_path.stat().st_size
            tmp_path = archived_path.with_name(archived_path.name + ".compact.tmp.opus")
            try:
                archived_path.parent.mkdir(parents=True, exist_ok=True)
                reencode_audio_to_opus(
                    input_path=input_path,
                    output_path=tmp_path,
                    bitrate=self.profile.archive_audio_bitrate,
                )
                new_bytes = tmp_path.stat().st_size
                if new_bytes <= 0:
                    raise RuntimeError(f"compaction produced empty file: {tmp_path}")
                shutil.move(str(tmp_path), str(archived_path))
                input_path.unlink(missing_ok=True)
                new_sha = sha256_file(archived_path)
                append_jsonl(
                    self.paths.audio_compactions_manifest,
                    {
                        "created_at": datetime.now(UTC).isoformat(),
                        "path": relative_path,
                        "archive_path": os.path.relpath(archived_path, self.paths.root),
                        "segment_id": row.get("segment_id"),
                        "target_bitrate": self.profile.archive_audio_bitrate,
                        "old_bytes": old_bytes,
                        "new_bytes": new_bytes,
                        "old_sha256": current_sha,
                        "new_sha256": new_sha,
                        "size_ratio": round(new_bytes / old_bytes, 4) if old_bytes > 0 else None,
                        "profile": self.profile.name,
                    },
                )
                compacted[(relative_path, self.profile.archive_audio_bitrate)] = new_sha
            except Exception:
                tmp_path.unlink(missing_ok=True)
                self.logger.exception("failed to compact audio path=%s", input_path)

    def _load_compacted_audio(self, relative_paths: set[str]) -> dict[tuple[str, str], str]:
        compacted: dict[tuple[str, str], str] = {}
        if not relative_paths:
            return compacted
        for row in iter_jsonl(self.paths.audio_compactions_manifest):
            path = str(row.get("path", ""))
            target_bitrate = str(row.get("target_bitrate", ""))
            new_sha = str(row.get("new_sha256", ""))
            if path in relative_paths and target_bitrate == self.profile.archive_audio_bitrate and new_sha:
                compacted[(path, target_bitrate)] = new_sha
        return compacted

    def _archive_audio_path(self, row: dict[str, object]) -> Path:
        started_at = datetime.fromisoformat(str(row["started_at"]))
        hour_dir = (
            self.paths.audio_archive_root
            / self.profile.name
            / f"{started_at:%Y}"
            / f"{started_at:%m}"
            / f"{started_at:%d}"
            / f"{started_at:%H}"
        )
        return hour_dir / Path(str(row["path"])).name

    def _resolve_audio_paths(self, batch: list[dict[str, object]]) -> list[Path]:
        originals = [self.paths.root / str(row["path"]) for row in batch]
        missing = {str(row["path"]) for row, path in zip(batch, originals) if not path.exists()}
        archived = self._latest_archive_paths(missing)
        resolved = []
        for row, original in zip(batch, originals):
            path = archived.get(str(row["path"]), original)
            if not path.exists():
                raise FileNotFoundError(f"missing segment audio: {original}")
            resolved.append(path)
        return resolved

    def _latest_archive_paths(self, relative_paths: set[str]) -> dict[str, Path]:
        paths: dict[str, Path] = {}
        if not relative_paths:
            return paths
        for record in iter_jsonl(self.paths.audio_compactions_manifest):
            original = str(record.get("path", ""))
            archive = str(record.get("archive_path", ""))
            if original in relative_paths and archive:
                paths[original] = self.paths.root / archive
        return paths

    def _set_cursor(self, line_count: int) -> None:
        self._read_offset, reached = jsonl_position(self.paths.segments_manifest, line_count)
        if reached != line_count:
            raise RuntimeError("manifest is shorter than its row checkpoint")
        self._read_cursor = line_count
        self._pending.clear()
        self._pending_offsets.clear()

    def _load_state(self, *, commit_state: bool = True) -> None:
        self._pending.clear()
        self._pending_offsets.clear()
        state_exists = self.state_file.exists()
        if state_exists:
            self._state = load_json(self.state_file)
            if "last_processed_line" not in self._state:
                raise RuntimeError("invalid worker checkpoint; refusing to skip or replay history")
            self._read_cursor = int(self._state["last_processed_line"])
            saved_offset = self._state.get("last_processed_offset")
            # An older worker can advance the line cursor during rollback but leave our keys unchanged.
            if self._state.get("last_processed_offset_line") != self._read_cursor:
                saved_offset = None
            if saved_offset is None:
                # One streaming migration from the deployed line-only checkpoint.
                self._set_cursor(self._read_cursor)
            else:
                self._read_offset = int(saved_offset)
                if self._read_cursor < 0:
                    raise RuntimeError("negative worker row checkpoint")
                read_jsonl_from_offset(self.paths.segments_manifest, self._read_offset, max_rows=0)
        else:
            # Preserve first-start behavior: process only records captured after startup.
            self._read_offset, self._read_cursor = jsonl_position(self.paths.segments_manifest)
            self._state = {"last_processed_line": self._read_cursor}
            saved_offset = None
        self._state["last_processed_offset"] = self._read_offset
        self._state["last_processed_offset_line"] = self._read_cursor
        self._state_loaded = True
        if commit_state and saved_offset is None:
            self._state["updated_at"] = datetime.now(UTC).isoformat()
            self._state["profile"] = self.profile.name
            write_json(self.state_file, self._state)

    def _commit_processed(self, processed_count: int) -> None:
        if processed_count <= 0:
            return
        self._state["last_processed_line"] = int(self._state.get("last_processed_line", 0)) + processed_count
        # Commit the processed prefix, never the read-ahead cursor.
        self._state["last_processed_offset"] = self._pending_offsets[processed_count - 1]
        self._state["last_processed_offset_line"] = self._state["last_processed_line"]
        self._state["updated_at"] = datetime.now(UTC).isoformat()
        self._state["profile"] = self.profile.name
        write_json(self.state_file, self._state)

    def _install_signal_handlers(self) -> None:
        def handle_stop(signum, frame) -> None:
            self.logger.info("received signal %s, stopping profile=%s", signum, self.profile.name)
            self._stop_event.set()

        signal.signal(signal.SIGINT, handle_stop)
        signal.signal(signal.SIGTERM, handle_stop)
