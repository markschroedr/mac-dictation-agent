from __future__ import annotations

import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Protocol

from .config import AppPaths


class AsrBackend(Protocol):
    def transcribe_files(self, input_paths: list[Path]) -> dict[str, object]:
        ...


class MacDictationAsrServiceBackend:
    def __init__(self, *, paths: AppPaths) -> None:
        self.paths = paths
        self.port = int(os.environ.get("MAC_DICTATION_ASR_PORT", "8766"))
        self.base_url = f"http://127.0.0.1:{self.port}"
        self.worker_dir = self._worker_dir()
        self._process: subprocess.Popen[bytes] | None = None

    def transcribe_files(self, input_paths: list[Path]) -> dict[str, object]:
        self._ensure_service()
        response = self._post_json(
            "/transcribe-file",
            {"paths": [str(path) for path in input_paths]},
            timeout=self._transcribe_timeout(),
        )
        if not response.get("ok"):
            raise RuntimeError(f"shared ASR worker failed: {response.get('error', 'unknown error')}")
        return {
            "input_paths": response.get("input_paths", [str(path) for path in input_paths]),
            "backend": response.get("backend", "parakeet-mlx"),
            "provider": response.get("provider", "mlx"),
            "model": response.get("model_name", ""),
            "audio_seconds": response.get("audio_seconds", 0),
            "elapsed_seconds": response.get("elapsed_seconds", 0),
            "total_seconds": response.get("total_seconds", 0),
            "rtf": response.get("rtf"),
            "lang": response.get("lang", ""),
            "segments": response.get("segments", []),
            "text": str(response.get("text", "") or "").strip(),
            "service_url": self.base_url,
            "memory": response.get("memory", {}),
        }

    def _ensure_service(self) -> None:
        if self._healthy():
            return
        self._start_service()
        deadline = time.monotonic() + float(os.environ.get("MAC_DICTATION_ASR_START_TIMEOUT_SECONDS", "30"))
        while time.monotonic() < deadline:
            if self._healthy():
                return
            if self._process is not None and self._process.poll() is not None:
                raise RuntimeError(f"shared ASR worker exited with status {self._process.returncode}")
            time.sleep(0.1)
        raise RuntimeError(f"shared ASR worker did not become healthy at {self.base_url}")

    def _healthy(self) -> bool:
        try:
            request = urllib.request.Request(f"{self.base_url}/health", method="GET")
            with urllib.request.urlopen(request, timeout=0.4) as response:
                return 200 <= response.status < 300
        except (OSError, urllib.error.URLError):
            return False

    def _start_service(self) -> None:
        if self.worker_dir is None:
            raise RuntimeError(
                "shared ASR worker is not running and MAC_DICTATION_ASR_WORKER_DIR is not set"
            )
        self.paths.logs_root.mkdir(parents=True, exist_ok=True)
        log_path = self.paths.logs_root / "shared-asr-worker.log"
        env = os.environ.copy()
        env.setdefault("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        env.setdefault("PERMANENT_TRANSCRIBER_ROOT", str(self.paths.root))
        model_root = self._shared_model_root()
        env.setdefault("MAC_DICTATION_MLX_CACHE", str(model_root / "mlx-cache"))
        env.setdefault("HF_HOME", str(model_root / "huggingface"))
        env.setdefault("HUGGINGFACE_HUB_CACHE", str(model_root / "huggingface/hub"))
        env.setdefault("XDG_CACHE_HOME", str(model_root / "xdg-cache"))
        with log_path.open("ab") as handle:
            self._process = subprocess.Popen(
                [
                    "uv",
                    "run",
                    "--frozen",
                    "uvicorn",
                    "server:app",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(self.port),
                ],
                cwd=self.worker_dir,
                stdout=handle,
                stderr=subprocess.STDOUT,
                env=env,
                start_new_session=True,
            )

    def _post_json(self, path: str, payload: dict[str, object], *, timeout: float) -> dict[str, object]:
        data = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"shared ASR HTTP {exc.code} on {path}: {body}") from exc
        except (OSError, urllib.error.URLError) as exc:
            raise RuntimeError(f"shared ASR request failed on {path}: {exc}") from exc

    def _transcribe_timeout(self) -> float:
        if value := os.environ.get("MAC_DICTATION_ASR_TRANSCRIBE_TIMEOUT_SECONDS"):
            return float(value)
        return 3600.0

    def _worker_dir(self) -> Path | None:
        if value := os.environ.get("MAC_DICTATION_ASR_WORKER_DIR"):
            return Path(value).expanduser().resolve()
        if value := os.environ.get("MAC_DICTATION_AGENT_ROOT"):
            candidate = Path(value).expanduser().resolve() / "asr_worker"
            if candidate.exists():
                return candidate
        return None

    def _shared_model_root(self) -> Path:
        if value := os.environ.get("MAC_DICTATION_MODEL_ROOT"):
            return Path(value).expanduser().resolve()
        if value := os.environ.get("MAC_DICTATION_DATA_ROOT"):
            return Path(value).expanduser().resolve() / "models"
        return Path.home() / "Library/Application Support/Mac Dictation Agent/models"


def create_backend(*, paths: AppPaths) -> AsrBackend:
    return MacDictationAsrServiceBackend(paths=paths)
