from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from pathlib import Path
from typing import Protocol


class AsrBackend(Protocol):
    def transcribe_files(self, input_paths: list[Path]) -> dict[str, object]:
        ...


class FluidAudioBackend:
    """Use the app-owned model. Never launch a second recognition service."""

    def __init__(self) -> None:
        port = int(os.environ.get("MAC_DICTATION_API_PORT", "8767"))
        self.base_url = f"http://127.0.0.1:{port}"

    def transcribe_files(self, input_paths: list[Path]) -> dict[str, object]:
        request = urllib.request.Request(
            f"{self.base_url}/transcribe-file",
            data=json.dumps({"paths": [str(path.resolve()) for path in input_paths]}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=3600) as response:
                result = json.load(response)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"FluidAudio HTTP {exc.code}: {body}") from exc
        except (OSError, urllib.error.URLError) as exc:
            raise RuntimeError(f"FluidAudio unavailable at {self.base_url}; keep Mac Dictation Agent running: {exc}") from exc
        return {**result, "input_paths": [str(path) for path in input_paths], "service_url": self.base_url}
