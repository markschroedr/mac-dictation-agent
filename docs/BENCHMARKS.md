# Dictation benchmark

This benchmark measures local Parakeet recognition after audio capture.

## Result

- Date: August 31, 2026.
- Mac: MacBook Air with Apple M4 and 16 GB RAM.
- Audio: 6.696 seconds, mono PCM at 16 kHz.
- Model: Parakeet TDT 0.6B v3, INT8 Core ML through FluidAudio.
- Runs: 5 warm runs in one helper process.
- Median recognition: 0.534 seconds.
- Median speed: 12.538 times real time.
- Range: 0.439 to 0.903 seconds.

The test sentence was:

> I wanted dictation to feel like a keyboard shortcut, so I built one that runs entirely on my Mac.

The model returned that sentence exactly in all five runs.

## Reproduce it

Build the release service. Then pass it a mono audio file:

```bash
swift build -c release --package-path swift-agent
bash scripts/benchmark_dictation.sh /path/to/audio.wav 5
```

The script warms the model once. It then uses a fresh transcription session for each run. It prints the median, range, speed, and transcript as JSON.

The first model download and Core ML preparation are not part of the warm result. A first dictation can take several minutes. Later app launches and warm dictations are much faster.
