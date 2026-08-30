from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from permanent_transcriber.config import default_paths
from permanent_transcriber.manifest import append_jsonl, load_json
from permanent_transcriber.worker import TranscriptionWorker, profile_for_name


class FakeBackend:
    def __init__(self) -> None:
        self.calls: list[list[Path]] = []

    def transcribe_files(self, input_paths: list[Path]) -> dict[str, object]:
        self.calls.append(input_paths)
        return {
            "text": f"batch {len(self.calls)}",
            "backend": "test-parakeet",
            "model": "test-parakeet",
            "provider": "test",
            "audio_seconds": 1.0,
            "elapsed_seconds": 0.1,
            "rtf": 0.1,
            "segments": [],
        }


class WorkerLifecycleTests(unittest.TestCase):
    def test_relaxed_profile_uses_safe_batches_and_short_polling(self) -> None:
        profile = profile_for_name("relaxed")
        self.assertEqual(profile.poll_seconds, 3.0)
        self.assertEqual(profile.batch_max_duration_ms, 5 * 60 * 1000)
        self.assertEqual(profile.shutdown_timeout_seconds, 180.0)

    def test_relaxed_worker_waits_for_full_batch_then_drains_remainder(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = default_paths(Path(temporary))
            paths.ensure()
            worker = TranscriptionWorker(paths=paths, profile="relaxed")
            worker.profile.compact_audio_after_transcribe = False
            worker.profile.diarize = False
            backend = FakeBackend()
            worker._backend = backend

            self._append_segment(paths.root, paths.segments_manifest, index=0, duration_ms=120_000)
            self._append_segment(paths.root, paths.segments_manifest, index=1, duration_ms=120_000)
            paths.state_root.mkdir(parents=True, exist_ok=True)
            paths.state_root.joinpath("worker-relaxed.json").write_text(
                json.dumps({"last_processed_line": 0}),
                encoding="utf-8",
            )

            self.assertEqual(worker._poll_and_process(flush_partial=False), 0)
            self.assertEqual(backend.calls, [])

            self._append_segment(paths.root, paths.segments_manifest, index=2, duration_ms=120_000)
            self.assertEqual(worker._poll_and_process(flush_partial=False), 2)
            self.assertEqual([len(call) for call in backend.calls], [2])
            self.assertEqual(load_json(worker.state_file, {})["last_processed_line"], 2)

            worker._drain_pending()
            self.assertEqual([len(call) for call in backend.calls], [2, 1])
            self.assertEqual(load_json(worker.state_file, {})["last_processed_line"], 3)

    def test_shutdown_drain_reads_segment_that_arrived_after_empty_poll(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = default_paths(Path(temporary))
            paths.ensure()
            worker = TranscriptionWorker(paths=paths, profile="relaxed")
            worker.profile.compact_audio_after_transcribe = False
            worker.profile.diarize = False
            backend = FakeBackend()
            worker._backend = backend

            self.assertEqual(worker._poll_and_process(flush_partial=False), 0)
            self.assertEqual(load_json(worker.state_file, {})["last_processed_line"], 0)
            self._append_segment(paths.root, paths.segments_manifest, index=0, duration_ms=1_000)

            worker._drain_pending()

            self.assertEqual([len(call) for call in backend.calls], [1])
            self.assertEqual(load_json(worker.state_file, {})["last_processed_line"], 1)

    @staticmethod
    def _append_segment(root: Path, manifest: Path, *, index: int, duration_ms: int) -> None:
        relative_path = Path("storage/audio") / f"segment-{index}.opus"
        audio_path = root / relative_path
        audio_path.parent.mkdir(parents=True, exist_ok=True)
        audio_path.write_bytes(b"audio")
        append_jsonl(
            manifest,
            {
                "segment_id": f"segment-{index}",
                "started_at": f"2026-08-04T10:00:{index:02d}+00:00",
                "ended_at": f"2026-08-04T10:00:{index + 1:02d}+00:00",
                "duration_ms": duration_ms,
                "path": str(relative_path),
            },
        )


if __name__ == "__main__":
    unittest.main()
