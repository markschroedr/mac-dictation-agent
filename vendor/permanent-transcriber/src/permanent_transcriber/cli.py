from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import typer

from .config import CaptureConfig, default_paths
from .capture_health import read_capture_health
from .process_state import read_live_pid

app = typer.Typer(help="Always-on local speech capture pipeline.")


def build_config(paths, device: str | None = None, announce: bool = True) -> CaptureConfig:
    from .device import resolve_input_device

    resolved_device, details = resolve_input_device(paths, requested=device)
    if announce:
        typer.echo(
            f"using input device [{details['strategy']}] {details['device']['index']}: {details['device']['name']}"
        )
    return CaptureConfig(input_device=resolved_device)


def read_pid(path: Path) -> int | None:
    return read_live_pid(path)


def ensure_capture_launch_allowed() -> None:
    if os.environ.get("SSH_CONNECTION") or os.environ.get("SSH_CLIENT"):
        raise RuntimeError(
            "microphone capture cannot be started through SSH; start it from Mac Dictation Agent so macOS can grant microphone access"
        )


def wait_for_capture_health(paths, process: subprocess.Popen[bytes], timeout_seconds: float) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        health = read_capture_health(paths.capture_health_file)
        if health.get("pid") == process.pid:
            if health.get("status") == "healthy":
                return
            if health.get("status") == "error":
                raise RuntimeError(str(health.get("error") or "audio capture failed"))
        exit_code = process.poll()
        if exit_code is not None:
            raise RuntimeError(f"audio capture exited during startup with status {exit_code}")
        time.sleep(0.05)
    raise RuntimeError("audio capture did not report a healthy microphone signal during startup")


def wait_for_worker_ready(paths, profile: str, process: subprocess.Popen[bytes], timeout_seconds: float = 5.0) -> None:
    deadline = time.monotonic() + timeout_seconds
    pid_file = worker_pid_file(paths, profile)
    while time.monotonic() < deadline:
        if read_live_pid(pid_file) == process.pid:
            return
        exit_code = process.poll()
        if exit_code is not None:
            raise RuntimeError(f"{profile} worker exited during startup with status {exit_code}")
        time.sleep(0.05)
    raise RuntimeError(f"{profile} worker did not report ready during startup")


def worker_pid_file(paths, profile: str) -> Path:
    return paths.state_root / f"worker-{profile}.pid"


def worker_state_file(paths, profile: str) -> Path:
    return paths.state_root / f"worker-{profile}.json"


@app.command()
def run(
    device: str | None = typer.Option(None, help="Input device name or index."),
) -> None:
    """Run the foreground audio capture loop."""
    from .capture import CaptureService, configure_logging

    try:
        ensure_capture_launch_allowed()
    except RuntimeError as exc:
        typer.echo(str(exc))
        raise typer.Exit(1)
    paths = default_paths()
    paths.ensure()
    configure_logging(paths.runtime_log)
    service = CaptureService(paths=paths, config=build_config(paths, device))
    try:
        service.run_forever()
    except RuntimeError as exc:
        typer.echo(str(exc))
        raise typer.Exit(1)


@app.command("worker-run")
def worker_run(
    profile: str = typer.Option("relaxed", help="Transcription profile: quick or relaxed."),
) -> None:
    """Run the transcription worker in the foreground."""
    from .capture import configure_logging
    from .worker import TranscriptionWorker

    paths = default_paths()
    paths.ensure()
    configure_logging(paths.worker_log)
    worker = TranscriptionWorker(paths=paths, profile=profile)
    try:
        worker.run_forever()
    except RuntimeError as exc:
        typer.echo(str(exc))
        raise typer.Exit(1)


@app.command("worker-once")
def worker_once(
    profile: str = typer.Option("relaxed", help="Transcription profile: quick or relaxed."),
    max_batches: int | None = typer.Option(1, min=1, help="Maximum batches to process."),
    max_segments: int | None = typer.Option(None, min=1, help="Maximum manifest segments to queue."),
    from_line: int | None = typer.Option(None, min=0, help="Read from this manifest line without committing state."),
    commit_state: bool = typer.Option(True, help="Commit profile cursor after processing."),
) -> None:
    """Run one bounded transcription pass."""
    from .capture import configure_logging
    from .worker import TranscriptionWorker

    paths = default_paths()
    paths.ensure()
    configure_logging(paths.worker_log)
    worker = TranscriptionWorker(paths=paths, profile=profile)
    processed = worker.run_once(
        max_batches=max_batches,
        max_segments=max_segments,
        from_line=from_line,
        commit_state=commit_state,
    )
    typer.echo(f"processed {processed} segment(s) profile={profile}")


@app.command()
def start(
    device: str | None = typer.Option(None, help="Input device name or index."),
    quick: bool = typer.Option(False, help="Start the quick provisional worker."),
) -> None:
    """Start capture and worker in the background."""
    from .capture import CaptureService
    from .worker import TranscriptionWorker

    try:
        ensure_capture_launch_allowed()
    except RuntimeError as exc:
        typer.echo(str(exc))
        raise typer.Exit(1)
    paths = default_paths()
    paths.ensure()
    config = build_config(paths, device)

    capture_existing = CaptureService.read_pid(paths.pid_file)
    if capture_existing is not None:
        typer.echo(f"capture already running with pid {capture_existing}")
        raise typer.Exit(1)

    profiles = []
    if quick:
        profiles.append("quick")
    profiles.append("relaxed")
    for profile in profiles:
        worker_existing = TranscriptionWorker(paths=paths, profile=profile).read_pid(
            TranscriptionWorker(paths=paths, profile=profile).pid_file
        )
        if worker_existing is not None:
            typer.echo(f"{profile} worker already running with pid {worker_existing}")
            raise typer.Exit(1)

    worker_processes: dict[str, subprocess.Popen[bytes]] = {}
    capture_process: subprocess.Popen[bytes] | None = None
    try:
        for profile in profiles:
            worker_cmd = [
                sys.executable,
                "-m",
                "permanent_transcriber.cli",
                "worker-run",
                "--profile",
                profile,
            ]
            with paths.worker_log.open("ab") as handle:
                worker_processes[profile] = subprocess.Popen(
                    worker_cmd,
                    cwd=paths.root,
                    stdout=handle,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
            wait_for_worker_ready(paths, profile, worker_processes[profile])

        capture_cmd = [sys.executable, "-m", "permanent_transcriber.cli", "run"]
        if device:
            capture_cmd.extend(["--device", device])
        paths.capture_health_file.unlink(missing_ok=True)
        with paths.runtime_log.open("ab") as handle:
            capture_process = subprocess.Popen(
                capture_cmd,
                cwd=paths.root,
                stdout=handle,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        wait_for_capture_health(
            paths,
            capture_process,
            timeout_seconds=config.digital_silence_timeout_seconds + 2.0,
        )
    except Exception as exc:
        if capture_process is not None and capture_process.poll() is None:
            try:
                capture_process.terminate()
                try:
                    capture_process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    capture_process.kill()
            except OSError:
                pass
        for profile in worker_processes:
            try:
                TranscriptionWorker(paths=paths, profile=profile).stop()
            except Exception:
                pass
        typer.echo(str(exc))
        raise typer.Exit(1)
    typer.echo(f"capture and workers started profiles={','.join(profiles)}")


@app.command()
def stop() -> None:
    """Stop background capture and worker."""
    from .capture import CaptureService
    from .worker import TranscriptionWorker

    paths = default_paths()
    capture_service = CaptureService(paths=paths, config=CaptureConfig())
    worker_services = [
        TranscriptionWorker(paths=paths, profile="quick"),
        TranscriptionWorker(paths=paths, profile="relaxed"),
    ]
    capture_stopped = capture_service.stop()
    worker_results = {worker.profile.name: worker.stop() for worker in worker_services}
    if not capture_stopped and not any(worker_results.values()):
        typer.echo("capture and worker are not running")
        raise typer.Exit(1)
    typer.echo(
        f"stop signal sent capture={str(capture_stopped).lower()} "
        + " ".join(f"{name}={str(stopped).lower()}" for name, stopped in worker_results.items())
    )


@app.command()
def status() -> None:
    """Show background capture and worker status."""
    paths = default_paths()
    capture_pid = read_pid(paths.pid_file)
    capture_health = read_capture_health(paths.capture_health_file)
    capture_healthy = (
        capture_pid is not None
        and capture_health.get("pid") == capture_pid
        and capture_health.get("status") == "healthy"
    )
    workers = {}
    for profile in ("quick", "relaxed"):
        pid_file = worker_pid_file(paths, profile)
        pid = read_pid(pid_file)
        workers[profile] = {
            "running": pid is not None,
            "pid": pid,
            "state_file": str(worker_state_file(paths, profile)),
        }
    print(
        json.dumps(
            {
                "capture": {
                    "running": capture_pid is not None,
                    "healthy": capture_healthy,
                    "pid": capture_pid,
                    "error": capture_health.get("error"),
                    "health_updated_at": capture_health.get("updated_at"),
                },
                "workers": workers,
            },
            indent=2,
        )
    )


@app.command()
def devices() -> None:
    """List input devices."""
    from .device import list_input_devices, load_app_config

    paths = default_paths()
    rows = list_input_devices()
    preferred = load_app_config(paths).get("preferred_input_device")
    for row in rows:
        row["is_preferred"] = str(row["index"]) == str(preferred)
    print(json.dumps(rows, indent=2))


@app.command("set-device")
def set_device_cmd(
    device: str = typer.Argument(..., help="Input device index or unique name fragment."),
) -> None:
    """Persist a preferred input device."""
    from .device import set_preferred_input_device

    paths = default_paths()
    paths.ensure()
    details = set_preferred_input_device(paths, device)
    typer.echo(
        f"preferred input device set to {details['device']['index']}: {details['device']['name']}"
    )


@app.command("clear-device")
def clear_device_cmd() -> None:
    """Clear the preferred input device override."""
    from .device import clear_preferred_input_device

    paths = default_paths()
    paths.ensure()
    clear_preferred_input_device(paths)
    typer.echo("preferred input device cleared")


@app.command()
def doctor() -> None:
    """Check local prerequisites for capture."""
    import sounddevice as sd

    from .device import list_input_devices, load_app_config, resolve_input_device

    paths = default_paths()
    result = {
        "project_root": str(paths.root),
        "ffmpeg": False,
        "input_device_count": 0,
        "default_input_device": None,
        "preferred_input_device": load_app_config(paths).get("preferred_input_device"),
        "resolved_input_device": None,
    }
    try:
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-version"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        result["ffmpeg"] = True
    except Exception:
        result["ffmpeg"] = False
    devices = sd.query_devices()
    input_rows = list_input_devices()
    result["input_device_count"] = len(input_rows)
    default_input, _default_output = sd.default.device
    if isinstance(default_input, int) and default_input >= 0 and default_input < len(devices):
        result["default_input_device"] = devices[default_input]["name"]
    try:
        _resolved_device, details = resolve_input_device(paths)
        result["resolved_input_device"] = details
    except RuntimeError as exc:
        result["resolved_input_device_error"] = str(exc)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    app()
