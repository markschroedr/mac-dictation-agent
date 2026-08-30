from __future__ import annotations

import json
import os
from pathlib import Path
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
from permanent_transcriber.config import default_paths
from permanent_transcriber.process_state import read_live_pid, write_process_state
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


class ProcessStateTests(unittest.TestCase):
    def test_stale_pid_is_removed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "capture.pid"
            path.write_text('{"pid": 999999, "started_at": "old", "command": "capture"}', encoding="utf-8")
            with patch("permanent_transcriber.process_state.process_snapshot", return_value=None):
                self.assertIsNone(read_live_pid(path))
            self.assertFalse(path.exists())

    def test_live_pid_is_returned(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "capture.pid"
            write_process_state(path)
            self.assertEqual(read_live_pid(path), os.getpid())

    def test_reused_pid_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "capture.pid"
            path.write_text('{"pid": 123, "started_at": "old", "command": "capture"}', encoding="utf-8")
            with patch(
                "permanent_transcriber.process_state.process_snapshot",
                return_value={"pid": 123, "started_at": "new", "command": "unrelated"},
            ):
                self.assertIsNone(read_live_pid(path))
            self.assertFalse(path.exists())


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


class FakeProcess:
    def __init__(self, pid: int) -> None:
        self.pid = pid

    def poll(self) -> None:
        return None


if __name__ == "__main__":
    unittest.main()
