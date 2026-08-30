from __future__ import annotations

import logging
import os
import queue
import signal
import time
from datetime import UTC, datetime
from pathlib import Path

import sounddevice as sd
import webrtcvad

from .config import AppPaths, CaptureConfig
from .capture_health import CaptureSignalMonitor, DigitalSilenceError, write_capture_health
from .process_state import read_live_pid, stop_process, write_process_state
from .segment_writer import FinalizedSegment, SegmentWriter
from .vad import VadSegmenter


class CaptureService:
    def __init__(self, paths: AppPaths, config: CaptureConfig) -> None:
        self.paths = paths
        self.config = config
        self.logger = logging.getLogger(__name__)
        self.frame_queue: queue.Queue[tuple[bytes, datetime] | None] = queue.Queue(
            maxsize=config.queue_max_frames
        )
        self.writer = SegmentWriter(paths=paths, config=config)
        self._stop = False
        self._dropped_frames = 0

    def run_forever(self) -> None:
        self.paths.ensure()
        self._write_pid()
        self.writer.start()
        monitor = CaptureSignalMonitor(self.config.digital_silence_timeout_seconds)
        healthy = False
        failed = False
        write_capture_health(
            self.paths.capture_health_file,
            status="starting",
            pid=os.getpid(),
            device=self.config.input_device,
        )
        vad = webrtcvad.Vad(self.config.vad_aggressiveness)
        segmenter = VadSegmenter(cfg=self.config, paths=self.paths, vad=vad)

        def callback(indata, frames, time_info, status) -> None:
            if status:
                self.logger.warning("audio callback status: %s", status)
            if frames <= 0:
                return
            payload = bytes(indata)
            now = datetime.now(UTC)
            try:
                self.frame_queue.put_nowait((payload, now))
            except queue.Full:
                self._dropped_frames += 1
                if self._dropped_frames == 1 or self._dropped_frames % 100 == 0:
                    self.logger.error("frame queue overflow; dropped_frames=%s", self._dropped_frames)

        self._install_signal_handlers()
        blocksize = self.config.sample_rate_hz * self.config.frame_ms // 1000
        try:
            with sd.RawInputStream(
                samplerate=self.config.sample_rate_hz,
                channels=self.config.channels,
                dtype="int16",
                blocksize=blocksize,
                callback=callback,
                device=self.config.input_device,
            ):
                self.logger.info("capture started")
                while not self._stop:
                    try:
                        item = self.frame_queue.get(timeout=1.0)
                    except queue.Empty:
                        monitor.check()
                        continue
                    if item is None:
                        break
                    frame, timestamp = item
                    monitor.observe(frame)
                    monitor.check()
                    if monitor.has_signal and not healthy:
                        healthy = True
                        write_capture_health(
                            self.paths.capture_health_file,
                            status="healthy",
                            pid=os.getpid(),
                            device=self.config.input_device,
                        )
                    event = segmenter.process_frame(frame, timestamp)
                    if event is not None:
                        self.writer.submit(
                            FinalizedSegment(
                                started_at=event.started_at,
                                ended_at=event.ended_at,
                                duration_ms=event.duration_ms,
                                pcm_path=event.pcm_path,
                            )
                        )
        except sd.PortAudioError as exc:
            failed = True
            error = RuntimeError(
                "failed to open input device; try `devices` and then pass `--device` explicitly"
            )
            self.logger.error("%s: %s", error, exc)
            write_capture_health(
                self.paths.capture_health_file,
                status="error",
                pid=os.getpid(),
                device=self.config.input_device,
                error=str(error),
            )
            raise error from exc
        except DigitalSilenceError as exc:
            failed = True
            self.logger.error("capture unhealthy: %s", exc)
            write_capture_health(
                self.paths.capture_health_file,
                status="error",
                pid=os.getpid(),
                device=self.config.input_device,
                error=str(exc),
            )
            raise
        except Exception as exc:
            failed = True
            self.logger.exception("capture failed")
            write_capture_health(
                self.paths.capture_health_file,
                status="error",
                pid=os.getpid(),
                device=self.config.input_device,
                error=str(exc),
            )
            raise
        finally:
            flushed = segmenter.flush(datetime.now(UTC))
            if flushed is not None:
                self.writer.submit(
                    FinalizedSegment(
                        started_at=flushed.started_at,
                        ended_at=flushed.ended_at,
                        duration_ms=flushed.duration_ms,
                        pcm_path=flushed.pcm_path,
                    )
                )
            self.writer.close()
            self._remove_pid()
            if not failed:
                write_capture_health(
                    self.paths.capture_health_file,
                    status="stopped",
                    pid=os.getpid(),
                    device=self.config.input_device,
                )
            self.logger.info("capture stopped")

    def stop(self) -> bool:
        return stop_process(self.paths.pid_file, timeout_seconds=10.0)

    @staticmethod
    def read_pid(path: Path) -> int | None:
        return read_live_pid(path)

    def _write_pid(self) -> None:
        existing = self.read_pid(self.paths.pid_file)
        if existing is not None:
            try:
                os.kill(existing, 0)
            except OSError:
                pass
            else:
                raise RuntimeError(f"capture already running with pid {existing}")
        write_process_state(self.paths.pid_file)

    def _remove_pid(self) -> None:
        self.paths.pid_file.unlink(missing_ok=True)

    def _install_signal_handlers(self) -> None:
        def handle_stop(signum, frame) -> None:
            self.logger.info("received signal %s, stopping", signum)
            self._stop = True

        signal.signal(signal.SIGINT, handle_stop)
        signal.signal(signal.SIGTERM, handle_stop)


def configure_logging(log_path: Path) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        handlers=[
            logging.FileHandler(log_path, encoding="utf-8"),
            logging.StreamHandler(),
        ],
    )
