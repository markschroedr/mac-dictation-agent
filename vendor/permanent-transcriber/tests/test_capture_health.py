from __future__ import annotations

from datetime import UTC, datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from permanent_transcriber.capture_health import (
    CaptureSignalMonitor,
    DigitalSilenceError,
    read_capture_health,
    write_capture_health,
)
from permanent_transcriber.cli import ensure_capture_launch_allowed, wait_for_capture_health, wait_for_worker_ready
from permanent_transcriber.config import CaptureConfig, default_paths
from permanent_transcriber.process_state import acquire_process_lock, read_live_pid, stop_process
from permanent_transcriber.vad import VadSegmenter
from permanent_transcriber.worker import TranscriptionWorker


class CaptureSignalMonitorTests(unittest.TestCase):
    def test_rejects_frame_less_stream(self) -> None:
        monitor = CaptureSignalMonitor(timeout_seconds=3.0, started_at=10.0)
        with self.assertRaisesRegex(DigitalSilenceError, "no audio frames"):
            monitor.check(now=13.0)

    def test_rejects_all_zero_stream(self) -> None:
        monitor = CaptureSignalMonitor(timeout_seconds=3.0, started_at=10.0)
        monitor.observe(bytes(960), now=10.1)
        with self.assertRaisesRegex(DigitalSilenceError, "only digital silence"):
            monitor.check(now=13.0)

    def test_real_signal_keeps_stream_healthy(self) -> None:
        monitor = CaptureSignalMonitor(timeout_seconds=3.0, started_at=10.0)
        monitor.observe(b"\x00\x00\x01\x00", now=12.5)
        monitor.check(now=15.4)
        self.assertTrue(monitor.has_signal)


class VadSegmenterTests(unittest.TestCase):
    def test_continuous_speech_is_rotated_at_maximum_segment_duration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = default_paths(Path(temporary))
            paths.ensure()
            config = CaptureConfig(frame_ms=30, min_segment_ms=30, max_segment_ms=90)
            segmenter = VadSegmenter(config, paths, AlwaysSpeechVad())
            started_at = datetime.now(UTC)

            self.assertIsNone(segmenter.process_frame(bytes(config.frame_bytes), started_at))
            self.assertIsNone(segmenter.process_frame(bytes(config.frame_bytes), started_at))
            event = segmenter.process_frame(bytes(config.frame_bytes), started_at)

            self.assertIsNotNone(event)
            self.assertEqual(event.duration_ms, 90)


class CaptureHealthFileTests(unittest.TestCase):
    def test_health_file_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "capture-health.json"
            write_capture_health(path, status="healthy", pid=123, device=0)
            self.assertEqual(
                {key: read_capture_health(path)[key] for key in ("status", "pid", "device")},
                {"status": "healthy", "pid": 123, "device": 0},
            )

    def test_startup_handshake_accepts_matching_healthy_capture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = default_paths(Path(temporary))
            process = FakeProcess(pid=123)
            write_capture_health(paths.capture_health_file, status="healthy", pid=123, device=0)
            wait_for_capture_health(paths, process, timeout_seconds=0.1)

    def test_startup_handshake_surfaces_capture_error(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = default_paths(Path(temporary))
            process = FakeProcess(pid=123)
            write_capture_health(
                paths.capture_health_file,
                status="error",
                pid=123,
                device=0,
                error="digital silence",
            )
            with self.assertRaisesRegex(RuntimeError, "digital silence"):
                wait_for_capture_health(paths, process, timeout_seconds=0.1)


class ProcessLockTests(unittest.TestCase):
    def test_live_holder_stays_visible_until_it_exits(self) -> None:
        # A live recorder that no check can see is how duplicate captures started.
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "capture.pid"
            holder = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import sys, time; from pathlib import Path; "
                    "from permanent_transcriber.process_state import acquire_process_lock; "
                    "acquire_process_lock(Path(sys.argv[1]), 'capture'); print(flush=True); time.sleep(60)",
                    str(path),
                ],
                stdout=subprocess.PIPE,
            )
            try:
                holder.stdout.readline()
                self.assertEqual(read_live_pid(path), holder.pid)
                with self.assertRaisesRegex(RuntimeError, f"already running with pid {holder.pid}"):
                    acquire_process_lock(path, "capture")
                self.assertEqual(read_live_pid(path), holder.pid)
                self.assertTrue(stop_process(path, timeout_seconds=5.0))
                self.assertIsNotNone(holder.poll())
                self.assertIsNone(read_live_pid(path))
            finally:
                holder.kill()
                holder.wait()


class WorkerStartupTests(unittest.TestCase):
    def test_worker_ready_requires_matching_process_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = default_paths(Path(temporary))
            process = FakeProcess(pid=123)
            with patch("permanent_transcriber.cli.read_live_pid", return_value=123):
                wait_for_worker_ready(paths, "relaxed", process, timeout_seconds=0.1)

    def test_initial_cursor_is_persisted_before_capture_starts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = default_paths(Path(temporary))
            paths.ensure()
            existing = [{"segment_id": "old-1"}, {"segment_id": "old-2"}]
            paths.segments_manifest.write_text(
                "".join(json.dumps(row) + "\n" for row in existing),
                encoding="utf-8",
            )
            worker = TranscriptionWorker(paths=paths, profile="relaxed")
            worker._load_state()

            state = json.loads(worker.state_file.read_text(encoding="utf-8"))
            self.assertEqual(state["last_processed_line"], 2)

            with paths.segments_manifest.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps({"segment_id": "new"}) + "\n")
            restarted = TranscriptionWorker(paths=paths, profile="relaxed")
            restarted._load_state()
            self.assertEqual(restarted._read_cursor, 2)


class CaptureLaunchTests(unittest.TestCase):
    def test_ssh_capture_is_rejected(self) -> None:
        with patch.dict(os.environ, {"SSH_CONNECTION": "client server"}, clear=False):
            with self.assertRaisesRegex(RuntimeError, "cannot be started through SSH"):
                ensure_capture_launch_allowed()

    def test_gui_capture_is_allowed(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            ensure_capture_launch_allowed()


class AlwaysSpeechVad:
    def is_speech(self, frame: bytes, sample_rate_hz: int) -> bool:
        return True


class FakeProcess:
    def __init__(self, pid: int) -> None:
        self.pid = pid

    def poll(self) -> None:
        return None


if __name__ == "__main__":
    unittest.main()
