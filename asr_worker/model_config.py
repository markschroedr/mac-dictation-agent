from __future__ import annotations

import os
from pathlib import Path


MODEL_NAME = os.environ.get("MAC_DICTATION_ASR_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")


def model_root() -> Path:
    return Path(
        os.environ.get(
            "MAC_DICTATION_MODEL_ROOT",
            Path.home() / "Library/Application Support/Mac Dictation Agent/models",
        )
    ).expanduser()


def mlx_cache_dir() -> Path:
    path = Path(os.environ.get("MAC_DICTATION_MLX_CACHE", model_root() / "mlx-cache")).expanduser()
    path.mkdir(parents=True, exist_ok=True)
    return path
