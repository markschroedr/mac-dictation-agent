from __future__ import annotations

import os
import resource
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import wave
from datetime import datetime
from pathlib import Path
from threading import Lock
from typing import Any

import mlx.core as mx
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse, Response
from parakeet_mlx import from_pretrained
from pydantic import BaseModel

from model_config import MODEL_NAME, mlx_cache_dir

try:
    from .stitching import commit_new_text, reset_session_text
except ImportError:
    from stitching import commit_new_text, reset_session_text

app = FastAPI()

MODEL_PRECISION = "bf16"
CONTEXT_SECONDS = 1.0
IDLE_EXIT_SECONDS = int(os.environ.get("MAC_DICTATION_ASR_IDLE_SECONDS", "60"))
WARMUP_AUDIO_SECONDS = 1.2

_model_lock = Lock()
_recognize_lock = Lock()
_warmup_lock = Lock()
_model: Any | None = None
_model_load_seconds: float | None = None
_warmup_seconds: float | None = None
_warmup_done = False
_session_lock = Lock()
_session_tails: dict[str, bytes] = {}
_session_chunk_responses: dict[tuple[str, int], dict[str, object]] = {}
_last_activity = time.monotonic()
_active_requests = 0
_shutting_down = False
_process_started = time.monotonic()


class ResetRequest(BaseModel):
    session_id: str


class TranscribePathRequest(BaseModel):
    session_id: str
    chunk_index: int = 1
    path: str
    final: bool = False


class TranscribeFileRequest(BaseModel):
    paths: list[str]


@app.on_event("startup")
def start_idle_watcher() -> None:
    log_event("worker startup backend=mlx")
    if IDLE_EXIT_SECONDS <= 0:
        log_event("idle exit disabled")
        return
    thread = threading.Thread(target=idle_exit_loop, daemon=True)
    thread.start()


@app.get("/health")
def health() -> dict[str, object]:
    touch()
    return {
        "ok": True,
        "service": "mac-dictation-asr",
        "api_version": 1,
        "backend": "mlx",
        "model_loaded": _model is not None,
        "model_load_seconds": _model_load_seconds,
        "warmup_seconds": _warmup_seconds,
        "model": MODEL_NAME,
        "precision": MODEL_PRECISION,
        "provider": "MLX/Metal",
        "context_seconds": CONTEXT_SECONDS,
        "idle_exit_seconds": IDLE_EXIT_SECONDS,
        "memory": memory_stats(),
    }


@app.post("/warmup")
def warmup() -> dict[str, object]:
    global _warmup_done, _warmup_seconds
    request_started()
    try:
        log_event("warmup endpoint begin")
        started = time.perf_counter()
        model = load_model()
        with _warmup_lock:
            if not _warmup_done:
                compile_started = time.perf_counter()
                with _recognize_lock:
                    run_synthetic_warmup(model)
                clear_metal_cache("warmup")
                _warmup_seconds = round(time.perf_counter() - compile_started, 3)
                _warmup_done = True
        total = time.perf_counter() - started
        log_event(f"warmup endpoint end total={total:.3f}s compile={_warmup_seconds or 0.0:.3f}s {memory_summary()}")
        return {
            "model_loaded": True,
            "model_load_seconds": _model_load_seconds,
            "warmup_seconds": round(total, 3),
            "compile_seconds": _warmup_seconds,
            "already_warmed": _warmup_done,
            "memory": memory_stats(),
        }
    finally:
        request_finished()


@app.post("/reset-session")
def reset_session(payload: ResetRequest) -> dict[str, object]:
    log_event(f"reset-session begin session={payload.session_id}")
    touch()
    clear_session(payload.session_id)
    log_event(f"reset-session end session={payload.session_id}")
    return {"session_id": payload.session_id, "reset": True}


def clear_session(session_id: str) -> None:
    with _session_lock:
        _session_tails.pop(session_id, None)
        for key in [key for key in _session_chunk_responses if key[0] == session_id]:
            _session_chunk_responses.pop(key, None)
    reset_session_text(session_id)


@app.post("/shutdown")
def shutdown() -> dict[str, object]:
    global _shutting_down
    log_event("shutdown requested")
    with _session_lock:
        should_start_exit = not _shutting_down
        _shutting_down = True
    if should_start_exit:
        threading.Thread(target=delayed_exit, daemon=True).start()
    return {"ok": True}


@app.post("/transcribe-path")
def transcribe_path(payload: TranscribePathRequest) -> dict[str, object]:
    request_started()
    try:
        return transcribe_path_service(payload)
    finally:
        request_finished()


def transcribe_path_service(payload: TranscribePathRequest) -> dict[str, object]:
    request_started_at = time.perf_counter()
    log_event(f"transcribe begin session={payload.session_id} chunk={payload.chunk_index} final={payload.final} path={payload.path}")
    cached = cached_chunk_response(payload.session_id, payload.chunk_index)
    if cached is not None:
        log_event(f"transcribe cached session={payload.session_id} chunk={payload.chunk_index}")
        return cached

    source_path = Path(payload.path).expanduser().resolve()
    if not source_path.exists():
        return {"error": f"audio file not found: {source_path}"}

    temp_dir = Path(tempfile.mkdtemp(prefix="mac-dictation-asr-"))
    try:
        wav_path = temp_dir / "input.wav"
        context_path = temp_dir / "context.wav"
        combined_path = temp_dir / "combined.wav"

        decode_started = time.perf_counter()
        decode_to_wav(source_path, wav_path)
        decode_seconds = time.perf_counter() - decode_started
        log_event(f"decode end session={payload.session_id} chunk={payload.chunk_index} decode={decode_seconds:.3f}s")

        audio_seconds = wav_duration_seconds(wav_path)
        context_seconds = write_context_wav(payload.session_id, context_path)
        recognition_path = wav_path
        recognition_seconds = audio_seconds
        if context_seconds > 0:
            concat_wavs(context_path, wav_path, combined_path)
            recognition_path = combined_path
            recognition_seconds = wav_duration_seconds(combined_path)

        with _recognize_lock:
            cached = cached_chunk_response(payload.session_id, payload.chunk_index)
            if cached is not None:
                log_event(f"transcribe cached after wait session={payload.session_id} chunk={payload.chunk_index}")
                return cached
            model = load_model()
            log_event(f"recognize begin session={payload.session_id} chunk={payload.chunk_index} audio={recognition_seconds:.3f}s")
            recognize_started = time.perf_counter()
            result = model.transcribe(str(recognition_path), dtype=mx.bfloat16)
            recognize_seconds = time.perf_counter() - recognize_started
            log_event(f"recognize end session={payload.session_id} chunk={payload.chunk_index} recognize={recognize_seconds:.3f}s")
            clear_metal_cache("transcribe")

        raw_segments = result_segments(result)
        new_segments = [segment for segment in raw_segments if float(segment.get("end", 0.0)) > context_seconds + 0.01]
        raw_text = " ".join(segment["text"].strip() for segment in new_segments if segment["text"].strip()).strip()
        if not raw_text:
            raw_text = str(getattr(result, "text", "") or "").strip()
        text = commit_new_text(payload.session_id, raw_text)
        store_tail(payload.session_id, wav_path)

        total_seconds = decode_seconds + recognize_seconds
        log_event(
            f"transcribe end session={payload.session_id} chunk={payload.chunk_index} "
            f"total={time.perf_counter() - request_started_at:.3f}s text_chars={len(text)}"
        )
        response = {
            "session_id": payload.session_id,
            "chunk_index": payload.chunk_index,
            "path": str(source_path),
            "duration_seconds": round(audio_seconds, 3),
            "recognition_audio_seconds": round(recognition_seconds, 3),
            "context_seconds": round(context_seconds, 3),
            "decode_seconds": round(decode_seconds, 3),
            "recognize_seconds": round(recognize_seconds, 3),
            "total_seconds": round(total_seconds, 3),
            "rtf": round(recognize_seconds / audio_seconds, 4) if audio_seconds > 0 else None,
            "speedup": round(audio_seconds / recognize_seconds, 2) if recognize_seconds > 0 else None,
            "raw_segment_count": len(raw_segments),
            "emitted_segment_count": len(new_segments),
            "segments": new_segments,
            "model": MODEL_NAME,
            "raw_text": raw_text,
            "text": text,
            "memory": memory_stats(),
        }
        store_chunk_response(payload.session_id, payload.chunk_index, response)
        return response
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


@app.post("/transcribe-file")
def transcribe_file(payload: TranscribeFileRequest) -> dict[str, object]:
    request_started()
    try:
        input_paths = [Path(value).expanduser().resolve() for value in payload.paths]
        if not input_paths:
            return {"ok": False, "error": "at least one audio path is required"}
        missing = [str(path) for path in input_paths if not path.is_file()]
        if missing:
            return {"ok": False, "error": "missing input files", "missing": missing}

        session_id = f"file-{uuid.uuid4().hex}"
        temp_dir: Path | None = None
        source_path = input_paths[0]
        service_started = time.perf_counter()
        try:
            if len(input_paths) > 1:
                temp_dir = Path(tempfile.mkdtemp(prefix="mac-dictation-asr-files-"))
                source_path = temp_dir / "combined.wav"
                combine_audio_files(input_paths, source_path, temp_dir)

            response = transcribe_path_service(
                TranscribePathRequest(
                    session_id=session_id,
                    chunk_index=1,
                    path=str(source_path),
                    final=True,
                )
            )
            if error := response.get("error"):
                return {"ok": False, "error": error}
            return {
                "ok": True,
                "input_paths": [str(path) for path in input_paths],
                "backend": "parakeet-mlx",
                "provider": "mlx",
                "model_name": response.get("model", MODEL_NAME),
                "precision": MODEL_PRECISION,
                "audio_seconds": response.get("duration_seconds"),
                "elapsed_seconds": response.get("recognize_seconds"),
                "total_seconds": response.get("total_seconds"),
                "service_elapsed_seconds": round(time.perf_counter() - service_started, 3),
                "rtf": response.get("rtf"),
                "segments": response.get("segments", []),
                "text": response.get("text", ""),
                "memory": response.get("memory", {}),
            }
        finally:
            clear_session(session_id)
            if temp_dir is not None:
                shutil.rmtree(temp_dir, ignore_errors=True)
    finally:
        request_finished()


@app.post("/v1/audio/transcriptions")
def openai_transcriptions(
    file: UploadFile = File(...),
    model: str = Form("whisper-large-v3"),
    response_format: str = Form("json"),
) -> Response:
    """OpenAI/Groq-compatible transcription endpoint.

    Accepts the same multipart request as api.groq.com/openai/v1/audio/transcriptions
    so clients only need to swap the base URL. The model field is accepted and
    ignored; transcription always uses the local Parakeet model.
    """
    if response_format not in {"json", "text", "verbose_json"}:
        return JSONResponse(
            status_code=400,
            content={"error": {"message": f"unsupported response_format: {response_format}", "type": "invalid_request_error"}},
        )
    session_id = f"openai-{uuid.uuid4().hex}"
    suffix = Path(file.filename or "").suffix or ".bin"
    temp_dir = Path(tempfile.mkdtemp(prefix="mac-dictation-openai-"))
    try:
        upload_path = temp_dir / f"upload{suffix}"
        with upload_path.open("wb") as handle:
            shutil.copyfileobj(file.file, handle)
        log_event(f"openai transcribe begin session={session_id} bytes={upload_path.stat().st_size} name={file.filename}")
        response = transcribe_path(
            TranscribePathRequest(session_id=session_id, chunk_index=1, path=str(upload_path), final=True)
        )
        if error := response.get("error"):
            return JSONResponse(
                status_code=400,
                content={"error": {"message": str(error), "type": "invalid_request_error"}},
            )
        text = str(response.get("text", ""))
        if response_format == "text":
            return PlainTextResponse(text)
        if response_format == "verbose_json":
            segments = [
                {"id": index, "start": segment["start"], "end": segment["end"], "text": segment["text"]}
                for index, segment in enumerate(response.get("segments", []))
            ]
            return JSONResponse(
                {
                    "task": "transcribe",
                    "duration": response.get("duration_seconds"),
                    "text": text,
                    "segments": segments,
                }
            )
        return JSONResponse({"text": text})
    finally:
        reset_session(ResetRequest(session_id=session_id))
        shutil.rmtree(temp_dir, ignore_errors=True)


def load_model() -> Any:
    global _model, _model_load_seconds
    if _model is not None:
        return _model
    with _model_lock:
        if _model is not None:
            return _model
        started = time.perf_counter()
        log_event("model load begin backend=mlx precision=bf16")
        cache_dir = mlx_cache_dir()
        _model = from_pretrained(MODEL_NAME, dtype=mx.bfloat16, cache_dir=cache_dir)
        _model_load_seconds = round(time.perf_counter() - started, 3)
        log_event(f"model load end total={_model_load_seconds:.3f}s")
        return _model

def run_synthetic_warmup(model: Any) -> None:
    temp_dir = Path(tempfile.mkdtemp(prefix="mac-dictation-mlx-warmup-"))
    try:
        path = temp_dir / "warmup.wav"
        silence_frames = b"\x00\x00" * int(16_000 * WARMUP_AUDIO_SECONDS)
        write_wav(path, silence_frames)
        model.transcribe(str(path), dtype=mx.bfloat16)
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def clear_metal_cache(label: str) -> None:
    try:
        mx.metal.clear_cache()
        log_event(f"metal cache cleared label={label} {memory_summary()}")
    except Exception as exc:
        log_event(f"metal cache clear failed label={label} error={type(exc).__name__}: {exc}")


def memory_stats() -> dict[str, object]:
    stats: dict[str, object] = {}
    try:
        peak_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        stats["peak_rss_mb"] = round(normalize_rss_to_bytes(peak_rss) / 1_000_000, 1)
    except Exception:
        pass
    try:
        stats["mlx_active_mb"] = round(mx.get_active_memory() / 1_000_000, 1)
        stats["mlx_cache_mb"] = round(mx.get_cache_memory() / 1_000_000, 1)
        stats["mlx_peak_mb"] = round(mx.get_peak_memory() / 1_000_000, 1)
    except Exception:
        pass
    return stats


def normalize_rss_to_bytes(value: int) -> int:
    if value > 10_000_000:
        return value
    return value * 1024


def memory_summary() -> str:
    stats = memory_stats()
    if not stats:
        return "memory=unavailable"
    parts = [f"{key}={value}" for key, value in stats.items()]
    return "memory " + " ".join(parts)


def result_segments(result: Any) -> list[dict[str, object]]:
    segments = []
    for sentence in getattr(result, "sentences", []) or []:
        text = str(getattr(sentence, "text", "") or "").strip()
        if not text:
            continue
        segments.append(
            {
                "text": text,
                "start": float(getattr(sentence, "start", 0.0) or 0.0),
                "end": float(getattr(sentence, "end", 0.0) or 0.0),
            }
        )
    return segments


def cached_chunk_response(session_id: str, chunk_index: int) -> dict[str, object] | None:
    with _session_lock:
        response = _session_chunk_responses.get((session_id, chunk_index))
    return dict(response) if response is not None else None


def store_chunk_response(session_id: str, chunk_index: int, response: dict[str, object]) -> None:
    with _session_lock:
        _session_chunk_responses[(session_id, chunk_index)] = dict(response)


def decode_to_wav(input_path: Path, output_path: Path) -> None:
    if input_path.suffix.lower() == ".wav":
        try:
            with wave.open(str(input_path), "rb") as handle:
                if handle.getnchannels() == 1 and handle.getframerate() == 16_000 and handle.getsampwidth() == 2:
                    shutil.copy2(input_path, output_path)
                    return
        except wave.Error:
            pass
    subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(input_path),
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(output_path),
        ],
        check=True,
    )


def combine_audio_files(input_paths: list[Path], output_path: Path, temp_dir: Path) -> None:
    frames = bytearray()
    for index, input_path in enumerate(input_paths):
        part_path = temp_dir / f"part-{index:04d}.wav"
        decode_to_wav(input_path, part_path)
        frames.extend(read_wav_frames(part_path))
    write_wav(output_path, bytes(frames))


def wav_duration_seconds(path: Path) -> float:
    with wave.open(str(path), "rb") as handle:
        return handle.getnframes() / handle.getframerate()


def write_context_wav(session_id: str, output_path: Path) -> float:
    with _session_lock:
        tail = _session_tails.get(session_id)
    if not tail:
        return 0.0
    write_wav(output_path, tail)
    return wav_duration_seconds(output_path)


def store_tail(session_id: str, wav_path: Path) -> None:
    with wave.open(str(wav_path), "rb") as handle:
        framerate = handle.getframerate()
        tail_frames = min(handle.getnframes(), int(CONTEXT_SECONDS * framerate))
        handle.setpos(handle.getnframes() - tail_frames)
        tail = handle.readframes(tail_frames)
    with _session_lock:
        _session_tails[session_id] = tail


def concat_wavs(first_path: Path, second_path: Path, output_path: Path) -> None:
    frames = read_wav_frames(first_path) + read_wav_frames(second_path)
    write_wav(output_path, frames)


def read_wav_frames(path: Path) -> bytes:
    with wave.open(str(path), "rb") as handle:
        if handle.getnchannels() != 1 or handle.getframerate() != 16_000 or handle.getsampwidth() != 2:
            raise RuntimeError(f"expected 16 kHz mono int16 WAV: {path}")
        return handle.readframes(handle.getnframes())


def write_wav(path: Path, frames: bytes) -> None:
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(16_000)
        handle.writeframes(frames)


def request_started() -> None:
    global _active_requests
    touch()
    with _session_lock:
        if _shutting_down:
            raise HTTPException(status_code=503, detail="ASR worker is shutting down")
        _active_requests += 1


def request_finished() -> None:
    global _active_requests
    touch()
    with _session_lock:
        _active_requests = max(0, _active_requests - 1)


def touch() -> None:
    global _last_activity
    _last_activity = time.monotonic()


def log_event(message: str) -> None:
    elapsed = time.monotonic() - _process_started
    timestamp = datetime.now().isoformat(timespec="milliseconds")
    print(f"[{timestamp} +{elapsed:.3f}s] {message}", flush=True)


def delayed_exit() -> None:
    time.sleep(0.2)
    while True:
        with _session_lock:
            active = _active_requests
        if active == 0:
            break
        time.sleep(0.05)
    log_event("worker exiting")
    os._exit(0)


def idle_exit_loop() -> None:
    while True:
        time.sleep(10)
        with _session_lock:
            idle_for = time.monotonic() - _last_activity
            active = _active_requests
        if active == 0 and idle_for >= IDLE_EXIT_SECONDS:
            log_event(f"idle exit after {idle_for:.1f}s")
            os._exit(0)
