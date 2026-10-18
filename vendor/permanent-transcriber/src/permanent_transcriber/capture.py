from __future__ import annotations

import logging
import os
import queue
import signal
import subprocess
import threading
import time
from datetime import UTC, datetime
from pathlib import Path

import sounddevice as sd
import webrtcvad

from .capture_health import (
    CaptureSignalMonitor,
    DigitalSilenceError,
    write_capture_health,
)
from .config import AppPaths, CaptureConfig
from .device import resolve_input_device
from .process_state import acquire_process_lock, read_live_pid, stop_process
from .segment_writer import FinalizedSegment, SegmentWriter
from .vad import VadSegmenter
from .source_tracks import SourceTracks

# A live input stream delivers a frame every 30 ms. This long without one means
# the device is gone (e.g. Bluetooth headset removed), not merely quiet.
MICROPHONE_LOSS_SECONDS = 2.0


class CaptureService:
    def __init__(self, paths: AppPaths, config: CaptureConfig) -> None:
        self.paths = paths
        self.config = config
        self.logger = logging.getLogger(__name__)
        self.frame_queue: queue.Queue[tuple[bytes, datetime] | None] = queue.Queue(
            maxsize=config.queue_max_frames
        )
        self.writer = None if config.include_system_audio else SegmentWriter(paths=paths, config=config)
        self._stop = False
        self._dropped_frames = 0
        self._system_audio_process: subprocess.Popen[bytes] | None = None
        self._system_audio_thread: threading.Thread | None = None
        self._source_tracks: SourceTracks | None = None
        self._system_audio_error: Exception | None = None
        self._stream: sd.RawInputStream | None = None

    def run_forever(self) -> None:
        self.paths.ensure()
        acquire_process_lock(self.paths.pid_file, "capture")
        if self.writer is not None:
            self.writer.start()
        monitor = CaptureSignalMonitor(self.config.digital_silence_timeout_seconds)
        healthy = False
        failed = False
        # The first failure is the cause; cleanup errors that follow are symptoms.
        first_error: str | None = None
        write_capture_health(
            self.paths.capture_health_file,
            status="starting",
            pid=os.getpid(),
            device=self.config.input_device,
        )
        segmenter = None if self.config.include_system_audio else VadSegmenter(
            cfg=self.config, paths=self.paths, vad=webrtcvad.Vad(self.config.vad_aggressiveness)
        )

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
            if self.config.include_system_audio:
                self._source_tracks = SourceTracks(self.paths.root, self.config.sample_rate_hz)
                self._start_system_audio(monitor)
            self._open_microphone(self.config.input_device, callback, blocksize)
            self.logger.info("capture started")
            last_frame_at = time.monotonic()
            try:
                while not self._stop:
                    if self._system_audio_error is not None:
                        raise RuntimeError("System audio capture failed") from self._system_audio_error
                    if self._dropped_frames:
                        raise RuntimeError("Microphone capture queue overflow; source recording is incomplete")
                    try:
                        item = self.frame_queue.get(timeout=0.5)
                    except queue.Empty:
                        if healthy and time.monotonic() - last_frame_at >= MICROPHONE_LOSS_SECONDS:
                            # Losing the microphone mid-recording is normal; keep recording.
                            self._switch_microphone(callback, blocksize, last_frame_at)
                            last_frame_at = time.monotonic()
                        elif not healthy:
                            monitor.check()
                        continue
                    if item is None:
                        break
                    frame, timestamp = item
                    last_frame_at = time.monotonic()
                    if self._source_tracks is not None:
                        self._source_tracks.write("microphone", frame)
                    monitor.observe(frame)
                    # Silence is fatal only at startup (missing permission). A muted
                    # or quiet microphone during a recording is still a recording.
                    if not healthy:
                        monitor.check()
                    if monitor.has_signal and not healthy:
                        healthy = True
                        write_capture_health(
                            self.paths.capture_health_file,
                            status="healthy",
                            pid=os.getpid(),
                            device=self.config.input_device,
                        )
                    event = segmenter.process_frame(frame, timestamp) if segmenter is not None else None
                    if event is not None:
                        assert self.writer is not None
                        self.writer.submit(
                            FinalizedSegment(
                                started_at=event.started_at,
                                ended_at=event.ended_at,
                                duration_ms=event.duration_ms,
                                pcm_path=event.pcm_path,
                            )
                        )
            finally:
                self._close_microphone()
        except sd.PortAudioError as exc:
            failed = True
            error = RuntimeError(
                "failed to open input device; try `devices` and then pass `--device` explicitly"
            )
            first_error = str(error)
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
            first_error = str(exc)
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
            first_error = str(exc)
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
            flushed = segmenter.flush(datetime.now(UTC)) if segmenter is not None else None
            if flushed is not None:
                assert self.writer is not None
                self.writer.submit(
                    FinalizedSegment(
                        started_at=flushed.started_at,
                        ended_at=flushed.ended_at,
                        duration_ms=flushed.duration_ms,
                        pcm_path=flushed.pcm_path,
                    )
                )
            # Terminating the helper below ends its output; that EOF is expected.
            self._stop = True
            try:
                self._stop_system_audio()
                if self._source_tracks is not None:
                    # Preserve queued microphone frames even when Stop was pressed.
                    try:
                        while not self.frame_queue.empty():
                            item = self.frame_queue.get_nowait()
                            if item is not None:
                                self._source_tracks.write("microphone", item[0])
                    finally:
                        self._source_tracks.close()
                    if self._system_audio_error is not None:
                        raise RuntimeError("System source audio is incomplete") from self._system_audio_error
                    if not failed:
                        (self._source_tracks.root / "closed.json").write_text('{}\n')
            except Exception as exc:
                failed = True
                first_error = first_error or str(exc)
                if self._source_tracks is not None:
                    (self._source_tracks.root / "capture-error.txt").write_text(first_error + '\n')
                write_capture_health(
                    self.paths.capture_health_file, status="error", pid=os.getpid(),
                    device=self.config.input_device, error=first_error,
                )
                raise
            finally:
                if self.writer is not None:
                    self.writer.close()
                if failed and self._source_tracks is not None:
                    error = self._source_tracks.root / "capture-error.txt"
                    if not error.exists():
                        error.write_text((first_error or 'Capture failed; source recording is incomplete') + '\n')
            if not failed:
                write_capture_health(
                    self.paths.capture_health_file,
                    status="stopped",
                    pid=os.getpid(),
                    device=self.config.input_device,
                )
            self.logger.info("capture stopped")

    def _open_microphone(self, device, callback, blocksize: int) -> None:
        self._stream = sd.RawInputStream(
            samplerate=self.config.sample_rate_hz,
            channels=self.config.channels,
            dtype="int16",
            blocksize=blocksize,
            callback=callback,
            device=device,
        )
        self._stream.start()

    def _close_microphone(self) -> None:
        stream, self._stream = self._stream, None
        if stream is None:
            return
        try:
            stream.abort()
            stream.close()
        except sd.PortAudioError as exc:
            self.logger.warning("closing lost microphone stream failed: %s", exc)

    def _switch_microphone(self, callback, blocksize: int, lost_at: float) -> None:
        self.logger.warning("microphone delivered no audio for %.1fs; switching to the current input device",
                            time.monotonic() - lost_at)
        self._close_microphone()
        while not self._stop:
            if self._system_audio_error is not None:
                raise RuntimeError("System audio capture failed") from self._system_audio_error
            try:
                # PortAudio reads the device list only at initialization.
                sd._terminate()
                sd._initialize()
                device, details = resolve_input_device(self.paths)
                self._open_microphone(device, callback, blocksize)
                break
            except (sd.PortAudioError, RuntimeError) as exc:
                self.logger.warning("no usable input device yet: %s", exc)
                time.sleep(1.0)
        else:
            return
        gap = time.monotonic() - lost_at
        if self._source_tracks is not None:
            # Silence keeps the microphone track aligned with system audio.
            samples = int(gap * self.config.sample_rate_hz) * self.config.channels
            self._source_tracks.write("microphone", bytes(2 * samples))
        self.logger.warning("microphone switched to %s after a %.1fs gap", details["device"]["name"], gap)
        write_capture_health(
            self.paths.capture_health_file, status="healthy", pid=os.getpid(), device=device,
        )

    def _start_system_audio(self, monitor: CaptureSignalMonitor) -> None:
        helper = self.config.system_audio_helper
        if not helper or not Path(helper).is_file():
            raise RuntimeError("system audio capture helper is missing; reinstall Mac Dictation Agent")
        self._system_audio_process = subprocess.Popen(
            [helper],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        time.sleep(0.5)
        if self._system_audio_process.poll() is not None:
            assert self._system_audio_process.stderr is not None
            detail = self._system_audio_process.stderr.read().decode("utf-8", errors="replace").strip()
            raise RuntimeError(detail or "system audio capture could not start")

        def read_audio() -> None:
            assert self._system_audio_process is not None
            assert self._system_audio_process.stdout is not None
            try:
                while True:
                    chunk = self._system_audio_process.stdout.read(32_000)
                    if not chunk:
                        if not self._stop:
                            raise RuntimeError("System audio helper ended unexpectedly")
                        break
                    assert self._source_tracks is not None
                    self._source_tracks.write("system", chunk)
                    monitor.observe(chunk)
            except Exception as exc:
                self._system_audio_error = exc

        self._system_audio_thread = threading.Thread(target=read_audio, daemon=True)
        self._system_audio_thread.start()

    def _stop_system_audio(self) -> None:
        process = self._system_audio_process
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
        if self._system_audio_thread is not None:
            self._system_audio_thread.join(timeout=5)
            if self._system_audio_thread.is_alive():
                raise RuntimeError("System audio reader did not stop; source recording is incomplete")

    def stop(self) -> bool:
        # Both encoders can each require 30 s to close, after the helper exits.
        return stop_process(self.paths.pid_file, timeout_seconds=75.0)

    @staticmethod
    def read_pid(path: Path) -> int | None:
        return read_live_pid(path)

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
