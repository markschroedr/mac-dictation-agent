from __future__ import annotations

import gc
import json
import os
import sys
import time
import uuid
from pathlib import Path
from typing import Any

MAXIMUM_INPUT_CHARACTERS = 100_000
# One dedicated 40M checkpoint per language; both are gated on Hugging Face.
MODELS = {
    "german": ("hf://gradium/phonon-40m-de", "de"),
    "english": ("hf://gradium/phonon-40m-en", "en"),
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
        if voice not in SUPPORTED_VOICES:
            raise ValueError(f"unsupported voice: {voice}")
        load_seconds = self._load(language)
        tts = self._models[language]

        started = time.monotonic()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path = output_path.with_name(
            f".{output_path.stem}.{uuid.uuid4().hex}.wav"
        )
        try:
            tts.save(
                str(temporary_path),
                text,
                voice=MALE_VOICES[language] if voice == "male" else None,
            )
            os.replace(temporary_path, output_path)
        finally:
            temporary_path.unlink(missing_ok=True)
        return (
            output_path.stat().st_size,
            load_seconds,
            time.monotonic() - started,
        )

    def unload(self) -> None:
        self._models.clear()
        gc.collect()

    def _load(self, language: str) -> float | None:
        if language in self._models:
            return None
        import ptts

        started = time.monotonic()
        self._models[language] = ptts.TTS(
            _model_source(language),
            lang=MODELS[language][1],
            quant="q8",
        )
        return time.monotonic() - started


def _response(request_id: str, **values: Any) -> dict[str, Any]:
    response: dict[str, Any] = {"id": request_id}
    response.update({key: value for key, value in values.items() if value is not None})
    return response


def _handle_request(
    runtime: ModelRuntime,
    request: dict[str, Any],
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
    if action != "synthesize":
        return _response(request_id, error=f"unsupported action: {action}"), False

    try:
        text = str(request.get("input") or "").strip()
        if not text:
            raise ValueError("synthesize requires non-empty input")
        if len(text) > MAXIMUM_INPUT_CHARACTERS:
            raise ValueError(f"input exceeds {MAXIMUM_INPUT_CHARACTERS} characters")
        language = str(request.get("language") or "")
        if language not in MODELS:
            raise ValueError(f"unsupported language: {language}")
        output_path = str(request.get("outputPath") or "")
        if not output_path:
            raise ValueError("synthesize requires outputPath")

        byte_count, load_seconds, synthesize_seconds = runtime.synthesize(
            text=text,
            language=language,
            voice=request.get("voice"),
            output_path=Path(output_path),
        )
        return (
            _response(
                request_id,
                outputPath=output_path,
                byteCount=byte_count,
                loadedLanguage=language,
                loadSeconds=load_seconds,
                synthesizeSeconds=synthesize_seconds,
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
                response, should_stop = _handle_request(runtime, request)
            except Exception as error:  # noqa: BLE001 - preserve worker process
                response, should_stop = _response("unknown", error=str(error)), False
            protocol.write(json.dumps(response, separators=(",", ":")) + "\n")
            protocol.flush()
            if should_stop:
                break
    finally:
        runtime.unload()


if __name__ == "__main__":
    main()
