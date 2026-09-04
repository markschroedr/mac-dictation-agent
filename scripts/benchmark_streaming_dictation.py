"""Replay a WAV at capture speed through the real FluidAudio helper.

Measures release-to-helper-result, not clipboard insertion or microphone capture.
Run with uv run scripts/benchmark_streaming_dictation.py --help.
"""

import argparse
import json
import os
import subprocess
import time
import wave
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "audio", type=Path, help="Mono 16 kHz PCM WAV; use synthetic or public speech"
    )
    parser.add_argument(
        "output",
        type=Path,
        help="New directory for chunks and raw results; retained for inspection",
    )
    parser.add_argument(
        "--durations", type=float, nargs="+", default=[6.7, 39, 306.7, 319]
    )
    parser.add_argument("--chunk-seconds", type=float, default=20)
    parser.add_argument("--postroll-seconds", type=float, default=0.45)
    args = parser.parse_args()
    if min(args.durations + [args.chunk_seconds]) <= 0 or args.postroll_seconds < 0:
        parser.error(
            "durations and chunk size must be positive; postroll must be nonnegative"
        )
    root = Path(__file__).resolve().parents[1]
    service = os.environ.get(
        "MAC_DICTATION_FLUID_SERVICE_BIN",
        str(root / "swift-agent/.build/release/FluidDictationService"),
    )
    with wave.open(str(args.audio)) as audio:
        if (audio.getnchannels(), audio.getframerate(), audio.getsampwidth()) != (
            1,
            16000,
            2,
        ):
            parser.error("audio must be mono 16 kHz 16-bit PCM")
        samples = audio.readframes(audio.getnframes())
    if len(samples) / 32000 < max(args.durations) + args.postroll_seconds:
        parser.error("input must cover the longest duration plus postroll")
    args.output.mkdir(parents=True, exist_ok=False)
    cases = []
    for case, duration in enumerate(args.durations):
        chunks = []
        start = 0.0
        while start < duration:
            final = start + args.chunk_seconds >= duration
            end = (
                duration + args.postroll_seconds
                if final
                else start + args.chunk_seconds
            )
            path = (args.output / f"case-{case}-chunk-{len(chunks) + 1}.wav").resolve()
            with wave.open(str(path), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(
                    samples[round(start * 16000) * 2 : round(end * 16000) * 2]
                )
            chunks.append((end, final, path, end - start))
            start = end
        cases.append((duration, chunks))
    results = {
        "service": Path(service).name,
        "chunk_seconds": args.chunk_seconds,
        "postroll_seconds": args.postroll_seconds,
        "cases": [],
    }
    with (args.output / "helper.log").open("w") as log:
        process = subprocess.Popen(
            [service],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=log,
            text=True,
        )

        def request(payload):
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            line = process.stdout.readline()
            if not line:
                raise RuntimeError("helper exited; inspect helper.log")
            response = json.loads(line)
            if response.get("error") or response.get("id") != payload["id"]:
                raise RuntimeError(response)
            return response

        try:
            warmup_start = time.monotonic()
            request({"id": "warmup", "action": "warmup", "final": False})
            results["model_load_seconds"] = time.monotonic() - warmup_start
            for case, (duration, chunks) in enumerate(cases):
                session = f"paced-{case}"
                request(
                    {
                        "id": session,
                        "action": "resetSession",
                        "sessionID": session,
                        "final": False,
                    }
                )
                started = time.monotonic()
                rows = []
                for index, (available, final, path, audio_seconds) in enumerate(
                    chunks, 1
                ):
                    time.sleep(max(0, started + available - time.monotonic()))
                    sent = time.monotonic()
                    response = request(
                        {
                            "id": f"{session}-{index}",
                            "action": "transcribe",
                            "sessionID": session,
                            "chunkIndex": index,
                            "path": str(path),
                            "final": final,
                        }
                    )
                    received = time.monotonic()
                    if not response.get("text", "").strip():
                        raise RuntimeError(
                            "empty transcript; do not count as a successful benchmark"
                        )
                    rows.append(
                        {
                            "index": index,
                            "final": final,
                            "audio_seconds": audio_seconds,
                            "available_at_seconds": available,
                            "queue_wait_seconds": sent - started - available,
                            "round_trip_seconds": received - sent,
                            "completed_at_seconds": received - started,
                            "response": response,
                        }
                    )
                result = {
                    "recording_seconds": duration,
                    "chunks": rows,
                    "release_to_result_seconds": received - started - duration,
                    "chunks_completed_before_release": sum(
                        r["completed_at_seconds"] <= duration for r in rows
                    ),
                }
                results["cases"].append(result)
                (args.output / "results.json").write_text(
                    json.dumps(results, indent=2) + "\n"
                )
                print(
                    json.dumps({k: v for k, v in result.items() if k != "chunks"}),
                    flush=True,
                )
            request({"id": "shutdown", "action": "shutdown", "final": False})
            process.wait(timeout=30)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=30)


if __name__ == "__main__":
    main()
