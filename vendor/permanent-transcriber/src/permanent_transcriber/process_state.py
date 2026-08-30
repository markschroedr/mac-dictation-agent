from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import time


def process_snapshot(pid: int) -> dict[str, object] | None:
    if pid <= 0:
        return None
    try:
        started_at = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "lstart="],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        command = subprocess.run(
            ["/bin/ps", "-ww", "-p", str(pid), "-o", "command="],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except subprocess.CalledProcessError:
        return None
    if not started_at or not command:
        return None
    return {"pid": pid, "started_at": started_at, "command": command}


def write_process_state(path: Path) -> None:
    snapshot = process_snapshot(os.getpid())
    if snapshot is None:
        raise RuntimeError("could not read current process identity")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(snapshot, sort_keys=True), encoding="utf-8")


def read_live_pid(path: Path) -> int | None:
    try:
        expected = json.loads(path.read_text(encoding="utf-8"))
        pid = int(expected["pid"])
        started_at = str(expected["started_at"])
        command = str(expected["command"])
    except (FileNotFoundError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        path.unlink(missing_ok=True)
        return None

    actual = process_snapshot(pid)
    if actual is None or actual["started_at"] != started_at or actual["command"] != command:
        path.unlink(missing_ok=True)
        return None
    return pid


def stop_process(path: Path, timeout_seconds: float = 5.0) -> bool:
    pid = read_live_pid(path)
    if pid is None:
        return False
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if read_live_pid(path) != pid:
            return True
        time.sleep(0.05)
    if read_live_pid(path) == pid:
        os.kill(pid, signal.SIGKILL)
        kill_deadline = time.monotonic() + 2.0
        while time.monotonic() < kill_deadline:
            if read_live_pid(path) != pid:
                return True
            time.sleep(0.05)
        raise RuntimeError(f"process {pid} did not exit after SIGKILL")
    path.unlink(missing_ok=True)
    return True
