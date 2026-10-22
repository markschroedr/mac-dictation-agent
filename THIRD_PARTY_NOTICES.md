# Third-party notices

Mac Dictation Agent's own code is MIT-licensed. Model weights and voice embeddings are not included in the repository or release archive. Workers download them from upstream when needed; the models retain their own licenses.

A free app does not make every use non-commercial. Review the model's terms for your actual use, including business or paid work. The app does not change upstream weights or claim ownership of them.

## Parakeet Ultra (transcription default)

- Core ML conversion: `FluidInference/parakeet-ultra-coreml`
- Original model: `moondream/parakeet-ultra`, a post-training of NVIDIA Parakeet TDT 0.6B v3
- License: Creative Commons Attribution 4.0 International (CC BY 4.0)
- Credit: Moondream (post-training), NVIDIA (base model), FluidInference (Core ML conversion)
- Core ML source: https://huggingface.co/FluidInference/parakeet-ultra-coreml
- Original source: https://huggingface.co/moondream/parakeet-ultra
- License text: https://creativecommons.org/licenses/by/4.0/legalcode.en

The models are not included in this repository or release archive. All transcription paths share the selected FluidAudio model.

## FluidAudio

- License: Apache License 2.0
- Source: https://github.com/FluidInference/FluidAudio

The Swift package revision is pinned in `swift-agent/Package.swift` and `swift-agent/Package.resolved`.

The native helper statically includes FluidAudio. Its Apache 2.0 license is in `THIRD_PARTY_LICENSES/FluidAudio-Apache-2.0.txt`. Upstream notices for fastcluster (Daniel Müllner and Google, BSD-2-Clause), VBx, and the Japanese/Spanish/French text frontends are preserved in `THIRD_PARTY_LICENSES/FluidAudio/`.

These notices also describe optional FluidAudio features, not additional app features. The app does not bundle Kokoro or LuxTTS models, dictionaries, or LuxTTS's GPL-derived lexicon/auxiliary data files. The native NeMo text-processing binary is disabled by the package's empty trait selection.

## Supertonic 3

- Python package: `supertonic` 1.3.1
- Package license: MIT
- Package source: https://github.com/supertone-inc/supertonic-py
- Model and included voices: `Supertone/supertonic-3`, Copyright (c) 2026 Supertone Inc.
- Model license: BigScience Open RAIL-M
- Model source: https://huggingface.co/Supertone/supertonic-3

The package and model are not bundled. The local TTS helper downloads model assets on first use. A verbatim copy of the upstream license, including Attachment A, is in `THIRD_PARTY_LICENSES/Supertonic-3-Open-RAIL-M.txt`.

The license permits commercial use subject to its use restrictions. Attachment A requires intelligible disclosure of machine-generated content and prohibits, among other uses, harmful deception and impersonation without consent. Read the full license before sharing generated speech or providing a hosted service; redistribution/hosting must pass on its license and enforceable use restrictions.

## Phonon 40M

- Python package: `ptts` 0.4.1
- Package license: MIT OR Apache-2.0
- Package source: https://github.com/gradium-ai/xn-ptts
- Models: `gradium/phonon-40m-de`, `gradium/phonon-40m-en`, by Gradium
- Model license: CC BY-NC 4.0, covering the weights, tokenizer and default voices in each model repository
- German source: https://huggingface.co/gradium/phonon-40m-de
- English source: https://huggingface.co/gradium/phonon-40m-en
- License text: https://creativecommons.org/licenses/by-nc/4.0/legalcode.en
- Upstream foundations: [Pocket TTS](https://github.com/kyutai-labs/pocket-tts) and Mimi, by Kyutai

**The 40M models do not allow commercial use.** The app's MIT license, the permissive runtime license and the catalog voice license do not remove this restriction. Obtain separate permission from Gradium for commercial use.

The package and models are not bundled. Both DE and EN 40M repositories are gated, with automatic approval after you accept each repository's terms. On each Mac, authenticate with `hf auth login` or supply `HF_TOKEN` in the app's private key file. The worker downloads all required model files automatically on first use; manual GGUF uploads are not required. Model caches and credentials do not travel in app updates. See [setup instructions](docs/USAGE.md#phonon-model-access).

### Phonon catalog voices

- Catalog: `gradium/phonon-voices`, by Gradium
- Selected male voices: Henrik (German), Miles (English)
- Catalog license: Apache License 2.0, separate from the 40M model license
- Source: https://huggingface.co/gradium/phonon-voices
- License text: https://www.apache.org/licenses/LICENSE-2.0

The runtime downloads the selected embedding when needed. These embeddings are not bundled or modified. The catalog's Apache license does not make the underlying 40M model commercially usable.

## Streaming Sortformer 4-speaker v2.1

- MLX conversion: `mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16`
- Original model: `nvidia/diar_streaming_sortformer_4spk-v2.1`
- License: NVIDIA Open Model License
- Attribution: Licensed by NVIDIA Corporation under the NVIDIA Open Model License
- MLX source: https://huggingface.co/mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16
- Original source: https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1
- License text: https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/

The model is not bundled. It is downloaded when microphone-only continuous transcription first attempts optional speaker diarization. The MLX conversion points to the original model; it does not grant a replacement license. The NVIDIA license allows commercial use subject to its conditions and [Trustworthy AI terms](https://www.nvidia.com/en-us/agreements/trustworthy-ai/terms/).

## External tools and cloud speech

- `uv` installs optional Python packages on the user's Mac; their runtime binaries and dependencies are not bundled.
- FFmpeg is an external executable, not bundled or linked into the app. Its LGPL/GPL license depends on the installed build: https://ffmpeg.org/legal.html.
- Inworld and xAI provide optional cloud speech through HTTP APIs. No provider model weights or SDKs are bundled. Users supply their own API keys; account, voice, output and acceptable-use terms apply, not the app's MIT license.
- Inworld: https://inworld.ai/terms-of-service and https://inworld.ai/service-specific-terms.
- xAI API: https://x.ai/legal/terms-of-service-enterprise and https://x.ai/legal/acceptable-use-policy.
- Do not present synthetic speech as a real person's recording or clone/impersonate someone without the necessary rights.

Python and Swift dependencies retain their respective licenses. Lockfiles under `supertonic_worker/`, `phonon_worker/`, `swift-agent/`, and `vendor/permanent-transcriber/` record the exact source-release dependency sets.
