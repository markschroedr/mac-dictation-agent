"""Single-instance process records.

A process holds an exclusive lock on its record file for its whole lifetime.
The kernel releases the lock only when the process exits, so the lock decides
whether the recorded process is alive. Nobody deletes a record: a stale file
without a lock holder simply means the process is gone.
"""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import signal
import time

_held_locks: dict[Path, int] = {}


def acquire_process_lock(path: Path, name: str) -> None:
    """Record the current process in PATH, or fail when another live process holds it."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(descriptor)
        raise RuntimeError(f"{name} already running with pid {read_live_pid(path)}") from None
    os.ftruncate(descriptor, 0)
    os.write(descriptor, json.dumps({"pid": os.getpid()}).encode())
    # Kept open, and not inherited by children, until this process exits.
    _held_locks[path] = descriptor


def read_live_pid(path: Path) -> int | None:
    try:
        descriptor = os.open(path, os.O_RDONLY)
    except FileNotFoundError:
        return None
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            return _recorded_pid(descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        return None
    finally:
        os.close(descriptor)


def _recorded_pid(descriptor: int) -> int:
    # The holder writes its pid right after locking; wait out that short window.
    deadline = time.monotonic() + 1.0
    while True:
        os.lseek(descriptor, 0, os.SEEK_SET)
        try:
            return int(json.loads(os.read(descriptor, 4096))["pid"])
        except (KeyError, TypeError, ValueError):
            if time.monotonic() >= deadline:
                raise RuntimeError("process record is locked but has no pid") from None
            time.sleep(0.01)


def stop_process(path: Path, timeout_seconds: float = 5.0) -> bool:
    """Signal the recorded process and return once it has actually exited."""
    pid = read_live_pid(path)
    if pid is None:
        return False
    os.kill(pid, signal.SIGTERM)
    if _wait_for_exit(path, timeout_seconds):
        return True
    os.kill(pid, signal.SIGKILL)
    if _wait_for_exit(path, 2.0):
        return True
    raise RuntimeError(f"process {pid} did not exit after SIGKILL")


def _wait_for_exit(path: Path, timeout_seconds: float) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if read_live_pid(path) is None:
            return True
        time.sleep(0.05)
    return read_live_pid(path) is None
