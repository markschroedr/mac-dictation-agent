# Third-party notices

Mac Dictation Agent downloads and uses the following models at runtime:

## Parakeet TDT 0.6B v3

- MLX conversion: `mlx-community/parakeet-tdt-0.6b-v3`
- Core ML conversion: `FluidInference/parakeet-tdt-0.6b-v3-coreml`
- Original model: NVIDIA NeMo Parakeet TDT 0.6B v3
- License: Creative Commons Attribution 4.0 International (CC BY 4.0)
- Source: https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3
- Core ML source: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml

The models are not included in this repository or release archive. Each transcription path downloads its model on first use.

## FluidAudio

- License: Apache License 2.0
- Source: https://github.com/FluidInference/FluidAudio

The Swift package revision is pinned in `swift-agent/Package.swift` and `swift-agent/Package.resolved`.

The release archive includes FluidAudio in the native helper binary. Its full Apache 2.0 license is included in `THIRD_PARTY_LICENSES/FluidAudio-Apache-2.0.txt`.

## Supertonic 3

- Python package: `supertonic` 1.3.1
- Package license: MIT
- Package source: https://github.com/supertone-inc/supertonic-py
- Model: `Supertone/supertonic-3`
- Model license: BigScience Open RAIL-M
- Model source: https://huggingface.co/Supertone/supertonic-3

The package and model are not included in this repository. The local TTS helper downloads model assets on first use. The model license contains use restrictions; review it before redistribution or hosted use.

## Streaming Sortformer 4-speaker v2.1

- MLX conversion: `mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16`
- Original model: `nvidia/diar_streaming_sortformer_4spk-v2.1`
- License: NVIDIA Open Model License
- MLX source: https://huggingface.co/mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16
- Original source: https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1
- License text: https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/

The model is not included in this repository. It is downloaded when canonical continuous transcription first attempts speaker diarization.

## parakeet-mlx

- License: Apache License 2.0
- Source: https://github.com/senstella/parakeet-mlx

Python and Swift dependencies retain their respective licenses. Lockfiles under `asr_worker/`, `supertonic_worker/`, `swift-agent/`, and `vendor/permanent-transcriber/` record the exact source-release dependency sets.
