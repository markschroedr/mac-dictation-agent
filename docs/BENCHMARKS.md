# Dictation timing

On an M4 MacBook Air, the paced benchmark finished about **0.6 seconds after release**, including after 5 minutes of speech.

This measures the wait for the transcription helper. It does not measure the final macOS clipboard/paste event.

## Results

September 4, 2026. MacBook Air, Apple M4, 16 GB RAM, macOS 26.5. Release-mode FluidAudio helper with Parakeet TDT 0.6B v3, INT8 Core ML. Models were already downloaded and loaded before each group of recordings.

| Recording length | Chunks finished before release | Final audio chunk, including post-roll | Release to helper result |
| --- | ---: | ---: | ---: |
| 6.7 seconds | 0 | 7.15 seconds | 0.627 seconds |
| 39 seconds | 1 | 19.45 seconds | 0.636 seconds |
| 5 minutes 6.7 seconds | 15 | 7.15 seconds | 0.602 seconds |
| 5 minutes 19 seconds | 15 | 19.45 seconds | 0.671 seconds |

These are individual runs, not averages. A separate group of 5 short recordings gave a **0.594-second median**, ranging from 0.551 to 0.621 seconds. Median final-chunk recognition alone was 0.139 seconds.

Loading the cached model into a new helper took about 17 seconds in both groups. That startup time is excluded from the table. The app starts loading during recording; a short recording after a cold start can still have to wait. The first model download and Core ML preparation can take much longer.

Raw responses and per-chunk timings:

- [Four paced recordings](https://github.com/markschroedr/mac-dictation-agent/blob/main/docs/benchmarks/2026-09-04-paced.json)
- [Five short repeats](https://github.com/markschroedr/mac-dictation-agent/blob/main/docs/benchmarks/2026-09-04-short.json)

## Why long recordings finish quickly

Hotkey and locked dictation rotate audio files every **20 seconds**. The helper processes each completed file while capture continues. Requests run serially, in capture order. The app pastes the combined text once all chunks finish.

After release, the recorder captures **450 ms of post-roll** to preserve the last word. The final chunk normally contains less than 20 seconds of speech plus this post-roll. The helper adds 1 second of silence for inference; that padding is not another second of waiting.

This is not a hard upper bound. Timer delays, a cold model, or a slow helper can leave more work queued. In these runs, every earlier chunk finished before release. Request scheduling delay stayed below 6 ms.

The separate continuous-transcription feature uses larger archival batches. Its 5-minute batch setting does not describe hotkey dictation.

## Method and limits

The benchmark splits a synthetic speech fixture into the app's 20-second chunks, with no overlap. It makes each chunk available at its capture deadline, in real time. A serial client sends each chunk to the real helper and waits for its response. The final chunk becomes available 450 ms after simulated release.

The recorded interval includes post-roll, scheduling delay, any pending recognition, IPC, and final recognition. It excludes microphone startup, actual AudioQueue file finalization, transcript saving, clipboard writes, and the receiving application's paste handling. It measures neither transcription accuracy nor end-to-end UI latency.

The fixture uses macOS Samantha speech, repeated to cover 320 seconds. Cuts can land inside words. This is a controlled latency check, not a diverse natural-speech evaluation. Results will vary with the voice, language, hardware, and system load.

## Reproduce

Build the helper, then create a synthetic fixture without recording your microphone:

```bash
swift build -c release --package-path swift-agent
mkdir benchmark-audio
say -v Samantha -r 165 -o benchmark-audio/speech.aiff \
  'I wanted dictation to feel like a keyboard shortcut, so I built one that runs entirely on my Mac. These are the notes for the next meeting. We need to finish the draft, review the schedule, and send the updated document tomorrow morning.'
ffmpeg -i benchmark-audio/speech.aiff -ac 1 -ar 16000 -c:a pcm_s16le benchmark-audio/short.wav
ffmpeg -stream_loop -1 -i benchmark-audio/short.wav -t 320 -c:a pcm_s16le benchmark-audio/long.wav
uv run scripts/benchmark_streaming_dictation.py benchmark-audio/long.wav benchmark-audio/paced
uv run scripts/benchmark_streaming_dictation.py benchmark-audio/long.wav benchmark-audio/repeats \
  --durations 6.7 6.7 6.7 6.7 6.7
```

The paced run takes about 11 minutes because it waits for capture deadlines. Output directories must be new. Chunks, helper logs, and raw JSON remain there for inspection. Keep generated audio and logs out of commits.

The defaults match `chunkSeconds = 20.0` and `finalChunkPostrollSeconds = 0.45` in `MacDictationAgent/main.swift`. Check those values if benchmarking another version. The measured helper came from source release `354b8c6`; its SHA-256 was `2c61766ed20bbfcc39d772faabf5572776a9b606c6657e2f3e1afad6d2c53d41`.

For recognition-only comparisons, the older `scripts/benchmark_dictation.sh` still accepts a single clip. Its August 31 result was 0.534 seconds median for a 6.696-second clip. That metric excludes post-roll and cannot describe the wait after a long dictation.

## Demo

The README animation is an illustration. Recording is shortened, the finishing pause is 0.65 seconds, and the transcript appears in one operation. It is not a screen recording or an end-to-end latency claim.
