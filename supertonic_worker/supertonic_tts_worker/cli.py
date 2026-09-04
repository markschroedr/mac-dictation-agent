from __future__ import annotations

import argparse
import contextlib
import gc
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from pydantic import BaseModel

MAXIMUM_INPUT_CHARACTERS = 100_000
SUPPORTED_LANGUAGES = {"english": "en", "german": "de"}
SUPPORTED_MODELS = {None, "supertonic", "supertonic-3"}
SUPPORTED_VOICES = {
    "F1",
    "F2",
    "F3",
    "F4",
    "F5",
    "M1",
    "M2",
    "M3",
    "M4",
    "M5",
}
DEFAULT_VOICE = "M1"
TOTAL_STEPS = 5


class SpeechRequest(BaseModel):
    model: str | None = None
    input: str
    voice: str | None = None
    response_format: str | None = None
    language: str | None = None


def _model_root() -> Path:
    configured = os.environ.get("MAC_DICTATION_SUPERTONIC_TTS_MODEL_ROOT")
    if configured:
        return Path(configured).expanduser()
    return (
        Path.home()
        / "Library"
        / "Application Support"
        / "Mac Dictation Agent"
        / "models"
        / "supertonic-3"
    )


class ModelRuntime:
    def __init__(self) -> None:
        self._tts: Any | None = None
        self._voice_style: Any | None = None
        self._voice: str | None = None
        self._language: str | None = None

    @property
    def loaded_language(self) -> str | None:
        return self._language

    def synthesize(
        self,
        *,
        text: str,
        language: str,
        voice: str | None,
        output_path: Path,
    ) -> tuple[int, float | None, float]:
        load_seconds = self._load(voice=voice)
        assert self._tts is not None
        assert self._voice_style is not None

        started = time.monotonic()
        with contextlib.redirect_stdout(sys.stderr):
            waveform, _ = self._tts.synthesize(
                text,
                self._voice_style,
                total_steps=TOTAL_STEPS,
                lang=SUPPORTED_LANGUAGES[language],
            )

        output_path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path = output_path.with_name(
            f".{output_path.stem}.{uuid.uuid4().hex}.wav"
        )
        try:
            with contextlib.redirect_stdout(sys.stderr):
                self._tts.save_audio(waveform, temporary_path)
            os.replace(temporary_path, output_path)
        finally:
            temporary_path.unlink(missing_ok=True)

        self._language = language
        return (
            output_path.stat().st_size,
            load_seconds,
            time.monotonic() - started,
        )

    def unload(self) -> None:
        self._voice_style = None
        self._tts = None
        self._voice = None
        self._language = None
        gc.collect()

    def _load(self, *, voice: str | None) -> float | None:
        selected_voice = voice or DEFAULT_VOICE
        if selected_voice not in SUPPORTED_VOICES:
            raise ValueError(f"unsupported voice: {selected_voice}")
        if self._tts is not None and self._voice == selected_voice:
            return None

        self.unload()
        root = _model_root()
        root.mkdir(parents=True, exist_ok=True)

        from supertonic import TTS

        started = time.monotonic()
        with contextlib.redirect_stdout(sys.stderr):
            tts = TTS(
                model="supertonic-3",
                model_dir=root,
                auto_download=True,
            )
            voice_style = tts.get_voice_style(selected_voice)
        self._tts = tts
        self._voice_style = voice_style
        self._voice = selected_voice
        return time.monotonic() - started


def _response(
    request_id: str,
    *,
    output_path: str | None = None,
    byte_count: int | None = None,
    loaded_language: str | None = None,
    load_seconds: float | None = None,
    synthesize_seconds: float | None = None,
    error: str | None = None,
) -> dict[str, Any]:
    response: dict[str, Any] = {"id": request_id}
    optional_values = {
        "outputPath": output_path,
        "byteCount": byte_count,
        "loadedLanguage": loaded_language,
        "loadSeconds": load_seconds,
        "synthesizeSeconds": synthesize_seconds,
        "error": error,
    }
    response.update(
        {key: value for key, value in optional_values.items() if value is not None}
    )
    return response


def _handle_worker_request(
    runtime: ModelRuntime,
    request: dict[str, Any],
) -> tuple[dict[str, Any], bool]:
    request_id = str(request.get("id") or "unknown")
    action = request.get("action")
    if action == "health":
        return _response(request_id, loaded_language=runtime.loaded_language), False
    if action == "unload":
        runtime.unload()
        return _response(request_id), False
    if action == "shutdown":
        return _response(request_id), True
    if action != "synthesize":
        return _response(request_id, error=f"unsupported action: {action}"), False

    try:
        text = str(request.get("input") or "").strip()
        if not text:
            raise ValueError("synthesize requires non-empty input")
        if len(text) > MAXIMUM_INPUT_CHARACTERS:
            raise ValueError(f"input exceeds {MAXIMUM_INPUT_CHARACTERS} characters")
        language = str(request.get("language") or "english")
        if language not in SUPPORTED_LANGUAGES:
            raise ValueError(f"unsupported language: {language}")
        raw_output_path = str(request.get("outputPath") or "")
        if not raw_output_path:
            raise ValueError("synthesize requires outputPath")

        byte_count, load_seconds, synthesize_seconds = runtime.synthesize(
            text=text,
            language=language,
            voice=request.get("voice"),
            output_path=Path(raw_output_path),
        )
        return (
            _response(
                request_id,
                output_path=raw_output_path,
                byte_count=byte_count,
                loaded_language=language,
                load_seconds=load_seconds,
                synthesize_seconds=synthesize_seconds,
            ),
            False,
        )
    except Exception as error:  # noqa: BLE001 - isolate model failures per request
        return (
            _response(
                request_id,
                loaded_language=runtime.loaded_language,
                error=str(error),
            ),
            False,
        )


def run_stdio_worker() -> int:
    runtime = ModelRuntime()
    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise TypeError("request must be a JSON object")
                response, should_stop = _handle_worker_request(runtime, request)
            except Exception as error:  # noqa: BLE001 - preserve worker process
                response = _response("unknown", error=str(error))
                should_stop = False
            sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
            sys.stdout.flush()
            if should_stop:
                break
    finally:
        runtime.unload()
    return 0


class WorkerProcess:
    def __init__(self, idle_seconds: float) -> None:
        self._idle_seconds = idle_seconds
        self._lock = threading.RLock()
        self._process: subprocess.Popen[str] | None = None
        self._idle_timer: threading.Timer | None = None
        self._loaded_language: str | None = None

    @property
    def loaded_language(self) -> str | None:
        with self._lock:
            if self._process is None or self._process.poll() is not None:
                return None
            return self._loaded_language

    def request(self, payload: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            self._cancel_idle_timer()
            for attempt in range(2):
                process = self._ensure_process()
                assert process.stdin is not None
                assert process.stdout is not None
                try:
                    process.stdin.write(
                        json.dumps(payload, separators=(",", ":")) + "\n"
                    )
                    process.stdin.flush()
                    line = process.stdout.readline()
                    if not line:
                        raise RuntimeError("Supertonic worker closed its output")
                    response = json.loads(line)
                    self._loaded_language = response.get("loadedLanguage")
                    self._schedule_idle_timer()
                    return response
                except (BrokenPipeError, json.JSONDecodeError, RuntimeError):
                    self._stop_locked()
                    if attempt == 1:
                        raise
            raise RuntimeError("Supertonic worker request failed")

    def stop(self) -> None:
        with self._lock:
            self._stop_locked()

    def _ensure_process(self) -> subprocess.Popen[str]:
        if self._process is not None and self._process.poll() is None:
            return self._process
        self._process = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "supertonic_tts_worker.cli",
                "--stdio-worker",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        return self._process

    def _cancel_idle_timer(self) -> None:
        if self._idle_timer is not None:
            self._idle_timer.cancel()
            self._idle_timer = None

    def _schedule_idle_timer(self) -> None:
        self._cancel_idle_timer()
        if self._idle_seconds <= 0:
            return
        self._idle_timer = threading.Timer(self._idle_seconds, self.stop)
        self._idle_timer.daemon = True
        self._idle_timer.start()

    def _stop_locked(self) -> None:
        self._cancel_idle_timer()
        process = self._process
        self._process = None
        self._loaded_language = None
        if process is None or process.poll() is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def _resolve_http_language(
    model: str | None,
    explicit_language: str | None,
) -> str:
    if model not in SUPPORTED_MODELS:
        raise ValueError(f"unsupported model: {model}")
    if explicit_language is None:
        return "english"
    if explicit_language not in SUPPORTED_LANGUAGES:
        raise ValueError(f"unsupported language: {explicit_language}")
    return explicit_language


def run_http_server(port: int) -> int:
    if os.environ.get("MAC_DICTATION_TTS_API_ENABLED") != "1":
        print(
            "HTTP API is disabled; set MAC_DICTATION_TTS_API_ENABLED=1 "
            "on the machine that should expose it",
            file=sys.stderr,
        )
        return 64

    import uvicorn
    from fastapi import FastAPI, Header, HTTPException
    from fastapi.responses import Response

    idle_seconds = float(os.environ.get("MAC_DICTATION_TTS_IDLE_SECONDS", "300"))
    api_token = os.environ.get("MAC_DICTATION_TTS_API_TOKEN")
    worker = WorkerProcess(idle_seconds=idle_seconds)
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

    def authorize(authorization: str | None) -> None:
        if api_token and authorization != f"Bearer {api_token}":
            raise HTTPException(
                status_code=401,
                detail="missing or invalid bearer token",
            )

    @app.get("/health")
    def health() -> dict[str, str]:
        response = {"id": str(uuid.uuid4()), "service": "supertonic-tts", "model": "supertonic-3"}
        if worker.loaded_language is not None:
            response["loadedLanguage"] = worker.loaded_language
        return response

    @app.post("/unload")
    def unload(authorization: str | None = Header(default=None)) -> dict[str, str]:
        authorize(authorization)
        worker.stop()
        return {"id": str(uuid.uuid4())}

    @app.post("/v1/audio/speech")
    def synthesize(
        speech: SpeechRequest,
        authorization: str | None = Header(default=None),
    ) -> Response:
        authorize(authorization)
        text = speech.input.strip()
        if not text:
            raise HTTPException(status_code=400, detail="input must not be empty")
        if len(text) > MAXIMUM_INPUT_CHARACTERS:
            raise HTTPException(
                status_code=400,
                detail=f"input exceeds {MAXIMUM_INPUT_CHARACTERS} characters",
            )
        if (
            speech.response_format is not None
            and speech.response_format.lower() != "wav"
        ):
            raise HTTPException(
                status_code=400,
                detail="response_format must be wav",
            )
        try:
            language = _resolve_http_language(speech.model, speech.language)
        except ValueError as error:
            raise HTTPException(status_code=400, detail=str(error)) from error

        request_id = str(uuid.uuid4())
        with tempfile.TemporaryDirectory(prefix="supertonic-http-") as directory:
            output_path = Path(directory) / "speech.wav"
            response = worker.request(
                {
                    "id": request_id,
                    "action": "synthesize",
                    "input": text,
                    "language": language,
                    "voice": speech.voice,
                    "outputPath": str(output_path),
                }
            )
            if response.get("error"):
                raise HTTPException(
                    status_code=500,
                    detail=response["error"],
                )
            return Response(
                content=output_path.read_bytes(),
                media_type="audio/wav",
            )

    try:
        uvicorn.run(
            app,
            host="127.0.0.1",
            port=port,
            log_level="info",
        )
    finally:
        worker.stop()
    return 0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stdio-worker", action="store_true")
    parser.add_argument("--http", action="store_true")
    parser.add_argument("--port", type=int, default=8767)
    arguments = parser.parse_args()

    if arguments.port < 1 or arguments.port > 65_535:
        parser.error("--port must be between 1 and 65535")
    if arguments.http:
        raise SystemExit(run_http_server(arguments.port))
    raise SystemExit(run_stdio_worker())


if __name__ == "__main__":
    main()
