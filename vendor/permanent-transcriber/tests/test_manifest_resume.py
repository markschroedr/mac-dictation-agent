"""Synthetic cursor regression: no lost/replayed rows across worker restarts."""
from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from permanent_transcriber.config import default_paths
from permanent_transcriber.manifest import append_jsonl, load_json
from permanent_transcriber.worker import TranscriptionWorker


class SyntheticBackend:
    def transcribe_files(self, input_paths):
        return {"text": "synthetic", "backend": "synthetic", "model": "none",
                "provider": "synthetic", "audio_seconds": 1, "elapsed_seconds": 0.01, "rtf": 0.01}


def segment(index):
    return {"segment_id": str(index), "started_at": "2000-01-01T00:00:00+00:00",
            "ended_at": "2000-01-01T00:00:01+00:00", "duration_ms": 2000,
            "path": "storage/audio/synthetic.opus", "synthetic_note": "ä"}


def worker(paths):
    instance = TranscriptionWorker(paths=paths, batch_max_segments=5, batch_max_duration_ms=3000, diarize=False)
    instance.profile.compact_audio_after_transcribe = False
    instance._backend = SyntheticBackend()
    return instance


class ManifestResumeTests(unittest.TestCase):
    def test_legacy_resume_read_ahead_and_incomplete_tail(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = default_paths(Path(temporary))
            paths.ensure()
            audio = paths.audio_root / "synthetic.opus"
            audio.write_bytes(b"synthetic")
            for index in range(17):
                append_jsonl(paths.segments_manifest, segment(index))
                with paths.segments_manifest.open("ab") as handle:
                    handle.write(b"\n")
            state = paths.state_root / "worker-relaxed.json"
            state.write_text(json.dumps({"last_processed_line": 4}))
            # Only one row fits the duration limit. Restart with buffered rows unread.
            self.assertEqual(worker(paths).run_once(max_batches=1), 1)
            checkpoint = load_json(state)
            self.assertEqual(checkpoint["last_processed_line"], 5)
            self.assertGreater(checkpoint["last_processed_offset"], 0)
            self.assertEqual(worker(paths).run_once(max_batches=1), 1)
            partial = json.dumps(segment(17), ensure_ascii=False).encode()
            with paths.segments_manifest.open("ab") as handle:
                handle.write(partial[:-3])
            worker(paths).run_once()
            with paths.segments_manifest.open("ab") as handle:
                handle.write(partial[-3:] + b"\n")
            worker(paths).run_once()
            worker(paths).run_once()
            # Independent oracle: the synthetic index range, not the saved checkpoint.
            ids = [identifier for line in paths.transcripts_manifest.read_text().splitlines()
                   for identifier in json.loads(line)["segment_ids"]]
            self.assertEqual(ids, [str(index) for index in range(4, 18)])
            self.assertEqual(load_json(state)["last_processed_line"], 18)
            self.assertEqual(load_json(state)["last_processed_offset"], paths.segments_manifest.stat().st_size)

    def test_pending_backlog_is_bounded_and_invalid_checkpoint_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = default_paths(Path(temporary))
            paths.ensure()
            (paths.audio_root / "synthetic.opus").write_bytes(b"synthetic")
            for index in range(100):
                append_jsonl(paths.segments_manifest, segment(index))
            state = paths.state_root / "worker-relaxed.json"
            state.write_text(json.dumps({"last_processed_line": 0}))
            instance = worker(paths)
            for _ in range(4):
                instance._poll_and_process()
                self.assertLessEqual(len(instance._pending), 5)
            state.write_text(json.dumps({"last_processed_line": 101}))
            with self.assertRaises(RuntimeError):
                worker(paths).run_once()


if __name__ == "__main__":
    unittest.main()
