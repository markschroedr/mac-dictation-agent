from __future__ import annotations

import base64
import gc
import json
import os
import sys
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any

import numpy as np

MAXIMUM_INPUT_CHARACTERS = 100_000
# One dedicated 40M checkpoint per language; both are gated on Hugging Face.
# Reason for pinned commits: ptts revalidates unpinned repos online on every load,
# which needs the token and network even when the model is cached.
MODELS = {
    "german": ("hf://gradium/phonon-40m-de@5c4137753f5595f3abd3f24df7ceae4455034d4c", "de"),
    "english": ("hf://gradium/phonon-40m-en@cc738b7e4d182c2ba1bafb8062aa4846af000637", "en"),
}
# Named voices from gradium/phonon-voices; `None` uses the checkpoint's own voice.
MALE_VOICES = {"german": "Henrik", "english": "Miles"}
SUPPORTED_VOICES = {None, "default", "male"}


def _model_source(language: str) -> str:
    override = os.environ.get(f"MAC_DICTATION_PHONON_{language.upper()}_MODEL")
    return override or MODELS[language][0]


class ModelRuntime:
    def __init__(self) -> None:
        self._models: dict[str, Any] = {}

    @property
    def loaded_language(self) -> str | None:
        return next(reversed(self._models), None)

    def synthesize(
        self,
        *,
        text: str,
        language: str,
        voice: str | None,
        output_path: Path,
    ) -> tuple[int, float | None, float]:
        load_seconds, tts, voice_name = self._prepare(language, voice)
        started = time.monotonic()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path = output_path.with_name(
            f".{output_path.stem}.{uuid.uuid4().hex}.wav"
        )
        try:
            tts.save(str(temporary_path), text, voice=voice_name)
            os.replace(temporary_path, output_path)
        finally:
            temporary_path.unlink(missing_ok=True)
        return (
            output_path.stat().st_size,
            load_seconds,
            time.monotonic() - started,
        )

    def stream(
        self,
        *,
        text: str,
        language: str,
        voice: str | None,
        emit: Callable[[bytes], None],
    ) -> tuple[int, float | None, float]:
        """Emit mono s16le PCM at the model sample rate while it is generated."""
        load_seconds, tts, voice_name = self._prepare(language, voice)
        started = time.monotonic()
        byte_count = 0
        with tts.stream(text, voice=voice_name) as audio:
            if audio.sample_rate != 24_000:
                raise ValueError(f"unexpected sample rate: {audio.sample_rate}")
            for chunk in audio:
                samples = np.asarray(chunk, dtype=np.float32).ravel()
                pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2").tobytes()
                byte_count += len(pcm)
                emit(pcm)
        return byte_count, load_seconds, time.monotonic() - started

    def unload(self) -> None:
        self._models.clear()
        gc.collect()

    def _prepare(
        self,
        language: str,
        voice: str | None,
    ) -> tuple[float | None, Any, str | None]:
        if voice not in SUPPORTED_VOICES:
            raise ValueError(f"unsupported voice: {voice}")
        load_seconds = None
        if language not in self._models:
            import ptts

            started = time.monotonic()
            self._models[language] = ptts.TTS(
                _model_source(language),
                lang=MODELS[language][1],
                quant="q8",
            )
            load_seconds = time.monotonic() - started
        voice_name = MALE_VOICES[language] if voice == "male" else None
        return load_seconds, self._models[language], voice_name


def _response(request_id: str, **values: Any) -> dict[str, Any]:
    response: dict[str, Any] = {"id": request_id}
    response.update({key: value for key, value in values.items() if value is not None})
    return response


def _handle_request(
    runtime: ModelRuntime,
    request: dict[str, Any],
    write: Callable[[dict[str, Any]], None],
) -> tuple[dict[str, Any], bool]:
    request_id = str(request.get("id") or "unknown")
    action = request.get("action")
    if action == "health":
        return _response(request_id, loadedLanguage=runtime.loaded_language), False
    if action == "unload":
        runtime.unload()
        return _response(request_id), False
    if action == "shutdown":
        return _response(request_id), True
    if action not in ("synthesize", "stream"):
        return _response(request_id, error=f"unsupported action: {action}"), False

    try:
        text = str(request.get("input") or "").strip()
        if not text:
            raise ValueError(f"{action} requires non-empty input")
        if len(text) > MAXIMUM_INPUT_CHARACTERS:
            raise ValueError(f"input exceeds {MAXIMUM_INPUT_CHARACTERS} characters")
        language = str(request.get("language") or "")
        if language not in MODELS:
            raise ValueError(f"unsupported language: {language}")
        voice = request.get("voice")
        output_path = None
        if action == "stream":
            # Audio lines carry the request id and precede its final response line.
            def emit(pcm: bytes) -> None:
                write(_response(request_id, audio=base64.b64encode(pcm).decode("ascii")))

            byte_count, load_seconds, seconds = runtime.stream(
                text=text, language=language, voice=voice, emit=emit
            )
        else:
            output_path = str(request.get("outputPath") or "")
            if not output_path:
                raise ValueError("synthesize requires outputPath")
            byte_count, load_seconds, seconds = runtime.synthesize(
                text=text, language=language, voice=voice, output_path=Path(output_path)
            )
        return (
            _response(
                request_id,
                outputPath=output_path,
                byteCount=byte_count,
                loadedLanguage=language,
                loadSeconds=load_seconds,
                synthesizeSeconds=seconds,
            ),
            False,
        )
    except Exception as error:  # noqa: BLE001 - isolate model failures per request
        return (
            _response(
                request_id,
                loadedLanguage=runtime.loaded_language,
                error=str(error),
            ),
            False,
        )


def main() -> None:
    # stdout carries the JSON-lines protocol; keep library output on stderr.
    protocol = sys.stdout
    sys.stdout = sys.stderr

    def write(response: dict[str, Any]) -> None:
        protocol.write(json.dumps(response, separators=(",", ":")) + "\n")
        protocol.flush()

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
                response, should_stop = _handle_request(runtime, request, write)
            except Exception as error:  # noqa: BLE001 - preserve worker process
                response, should_stop = _response("unknown", error=str(error)), False
            write(response)
            if should_stop:
                break
    finally:
        runtime.unload()


if __name__ == "__main__":
    main()
