from __future__ import annotations

from pathlib import Path
import shutil
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch
import wave

import numpy as np

from permanent_transcriber.config import AppPaths
from permanent_transcriber.diarization import SortformerDiarizer


class FakeStreamingModel:
    def __init__(self) -> None:
        self.chunk_lengths: list[int] = []

    def generate(self, *_args: object, **_kwargs: object) -> object:
        raise AssertionError("non-streaming Sortformer inference must not be used")

    def generate_stream(self, chunks: object, **_kwargs: object) -> object:
        for chunk in chunks:
            self.chunk_lengths.append(len(chunk))
            yield SimpleNamespace(segments=[])


class DiarizationStreamingTests(unittest.TestCase):
    def test_diarizer_uses_streaming_model_with_bounded_chunks(self) -> None:
        sample_rate = 16_000
        total_frames = sample_rate * 12 + sample_rate // 2

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.wav"
            with wave.open(str(source), "wb") as handle:
                handle.setnchannels(1)
                handle.setsampwidth(2)
                handle.setframerate(sample_rate)
                handle.writeframes(np.zeros(total_frames, dtype="<i2").tobytes())

            memory = {"limit": 0, "cache_limit": 0, "peak": 0}
            mlx_core = ModuleType("mlx.core")

            def set_memory_limit(value: int) -> int:
                previous = memory["limit"]
                memory["limit"] = value
                return previous

            def set_cache_limit(value: int) -> int:
                previous = memory["cache_limit"]
                memory["cache_limit"] = value
                return previous

            mlx_core.set_memory_limit = set_memory_limit
            mlx_core.set_cache_limit = set_cache_limit
            mlx_core.reset_peak_memory = lambda: memory.update(peak=0)
            mlx_core.get_peak_memory = lambda: memory["peak"]
            mlx_core.clear_cache = lambda: None
            mlx = ModuleType("mlx")
            mlx.core = mlx_core

            model = FakeStreamingModel()
            diarizer = SortformerDiarizer(paths=AppPaths.from_root(root / "runtime"))
            diarizer._model = model
            with (
                patch.dict(sys.modules, {"mlx": mlx, "mlx.core": mlx_core}),
                patch(
                    "permanent_transcriber.diarization.concat_to_wav",
                    side_effect=lambda _inputs, output: shutil.copyfile(source, output),
                ),
            ):
                result = diarizer.diarize([source], [], "")

        self.assertEqual(model.chunk_lengths, [80_000, 80_000, 40_000])
        self.assertEqual(result["chunk_count"], 3)
        self.assertEqual(result["chunk_seconds"], 5.0)


if __name__ == "__main__":
    unittest.main()
