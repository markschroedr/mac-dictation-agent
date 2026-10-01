"""Real encoder → permanent worker → shared ASR → source transcript journey.

Run with the installed permanent-transcriber Python. Set MAC_DICTATION_AGENT_ROOT
when the shared ASR service is not already running. Artifacts remain in /tmp.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "vendor/permanent-transcriber/src"))
from permanent_transcriber.source_tracks import SourceTracks


def wait_for(predicate, message: str, seconds: int = 120) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise AssertionError(message)


def speech(root: Path, name: str, text: str) -> bytes:
    path = root / (name + ".aiff")
    subprocess.run(["say", "-v", "Samantha", "-o", str(path), text], check=True)
    return subprocess.check_output([
        "ffmpeg", "-v", "error", "-i", str(path), "-ar", "16000", "-ac", "1", "-f", "s16le", "pipe:1",
    ])


def main() -> None:
    root = Path(tempfile.mkdtemp(prefix="source-worker-e2e-"))
    print(f"Artifacts: {root}", flush=True)
    remote = speech(root, "remote", "The remote speaker says the purple telescope is ready.")
    local = speech(root, "local", "My microphone question is where we should meet tomorrow.")
    tail = speech(root, "tail", "The final microphone sentence belongs to the last audio chunk.")
    microphone = bytearray(70 * 32000)
    system = bytearray(70 * 32000)
    microphone[32000:32000 + len(remote)] = remote
    system[32000:32000 + len(remote)] = remote
    microphone[4 * 32000:4 * 32000 + len(local)] = local
    microphone[62 * 32000:62 * 32000 + len(tail)] = tail
    tracks = SourceTracks(root, 16000)
    # Feed in interleaved seconds, keeping the real encoder pipes open.
    for second in range(70):
        begin = second * 32000
        tracks.write("microphone", bytes(microphone[begin:begin + 32000]))
        tracks.write("system", bytes(system[begin:begin + 32000]))
    session = tracks.root
    env = os.environ.copy()
    env["PYTHONPATH"] = str(REPO / "vendor/permanent-transcriber/src")
    env["PERMANENT_TRANSCRIBER_ROOT"] = str(root)
    command = [sys.executable, "-m", "permanent_transcriber.cli"]
    output = root / "storage/transcripts/participants" / (session.name + ".txt")
    with (root / "worker.log").open("wb") as log:
        worker = subprocess.Popen(command + ["worker-run"], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_for(lambda: output.exists() and "tomorrow" in output.read_text().lower(),
                     "The live worker did not publish the completed source chunks")
            live = output.read_text()
            assert not (session / "closed.json").exists(), "Capture was already closed"
            assert live.lower().count("telescope") == 1, "Echo was duplicated or remote speech lost"
            assert "Microphone:" in live and "Remote:" in live, "Source attribution is missing"
            for source in ("microphone", "system"):
                assert (session / source / "000000-asr.json").exists(), "Closed chunk was not transcribed"
                assert not (session / source / "000001-asr.json").exists(), "Worker read the open tail chunk"
            assert "final" not in live.lower(), "Unpublished tail entered the live transcript"
            print("PASS: transcript appeared during capture; open chunks were not consumed", flush=True)
            cached = {path: path.stat().st_mtime_ns for path in session.glob("*/*-asr.json")}
            # Simulate a worker interruption while capture still has an open
            # tail. Restart must resume from the existing on-disk ASR results.
            worker.send_signal(signal.SIGTERM)
            assert worker.wait(timeout=180) == 0, "Interrupted worker did not exit"
            status = json.loads(subprocess.check_output(command + ["status"], env=env))
            assert status["source_pending"] and not status["workers"]["relaxed"]["running"], "Pending work was lost"
            worker = subprocess.Popen(command + ["worker-run"], env=env, stdout=log, stderr=subprocess.STDOUT)
            wait_for(lambda: json.loads(subprocess.check_output(command + ["status"], env=env))
                     ["workers"]["relaxed"]["pid"] == worker.pid, "Replacement worker did not start", seconds=10)
            # Stop acquisition first, then signal the SAME worker to drain.
            tracks.close()
            (session / "closed.json").write_text("{}\n")
            audio_hashes = {path: hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in session.glob("*/*.opus")}
            worker.send_signal(signal.SIGTERM)
            assert worker.wait(timeout=180) == 0, "Worker did not finish its shutdown drain"
            info = json.loads((session / "participants.json").read_text())
            final = output.read_text()
            assert info["complete"] and info["cached_chunks"] == 4, "Final source chunks were not drained"
            assert final.startswith(live), "Already published conversation changed after Stop"
            assert "final" in final.lower(), "Final microphone speech is missing"
            for path, modified in cached.items():
                assert path.stat().st_mtime_ns == modified, "Completed source audio was transcribed again"
            for path, digest in audio_hashes.items():
                assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, "Original Opus was changed"
            mixed = root / "storage/manifests/segments.jsonl"
            assert not mixed.exists() or not mixed.read_text().strip(), "Dual capture produced mixed audio jobs"
            before = {path: path.stat().st_mtime_ns for path in session.glob("*/*-asr.json")}
            subprocess.run(command + ["worker-once"], env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            assert all(path.stat().st_mtime_ns == modified for path, modified in before.items()), "Restart repeated ASR"
            print("PASS: shutdown drained the tail; restart reused caches; original Opus unchanged", flush=True)
            print(f"Transcript: {output}", flush=True)
        finally:
            if worker.poll() is None:
                worker.terminate()
                try:
                    worker.wait(timeout=180)
                except subprocess.TimeoutExpired:
                    worker.kill()
                    worker.wait()
            if any(process.poll() is None for process, _ in tracks.streams.values()):
                tracks.close()


if __name__ == "__main__":
    main()
