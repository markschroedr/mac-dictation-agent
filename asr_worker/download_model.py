from __future__ import annotations

from huggingface_hub import snapshot_download

from model_config import MODEL_NAME, mlx_cache_dir


def main() -> None:
    model_path = snapshot_download(repo_id=MODEL_NAME, cache_dir=mlx_cache_dir())
    print(f"Model ready: {model_path}")


if __name__ == "__main__":
    main()
