# Changelog

## 0.2.0 - 2026-10-06

### Dictation

- Added Control+Command dictation that records the microphone and system audio together and pastes timestamped `Mic` and `System` lines.
- Kept every dictation in a durable recovery session, including failed and empty ones.
- Kept the Fluid model loaded so a cold start no longer delays the first chunk.
- Made start, stop, and error sounds a Settings toggle, off by default.

### Transcription API

- Served hotkey-dictation transcription on an OpenAI-compatible loopback endpoint that honors `response_format`.
- Removed the MLX worker's separate transcription endpoint.

### Continuous recording

- Included system audio by default and asked for permission as soon as it is selected.
- Preserved separate microphone and system Opus source tracks.
- Added experimental per-source participant transcripts, matched by timing instead of echo cancellation.
- Rotated continuous speech into segments after four minutes and held a process lock for the recorder's lifetime.
- Kept the status menu responsive during stop and processing, and loaded menu data in the background with paged recent transcripts.

### Files and speech

- Recognized file transcriptions in 60-second windows with 15-second overlap. One 300-second batch previously peaked at 8.7 GB of MLX memory and crashed the shared ASR service on a 16 GB Mac.
- Streamed progressive speech through one continuous VLC response.

### Installation

- Kept only the active runtime and the one it replaced after a successful activation.

## 0.1.3 - 2026-09-07

- Start speech playback with a short first chunk while later chunks generate.
- Play chunks in text order through VLC without restarting after Stop.
- Save a joined recording after generation: WAV for local speech, M4A for multi-chunk cloud speech.
- Add a CLI benchmark for audio readiness and observed VLC playback latency.

## 0.1.2 - 2026-09-05

- Added configurable Quick Speak Clipboard presets without a default cloud provider.
- Added voice setup guidance and access to the dedicated API key file.
- Added Supertonic service identification for shared-service consumers.
- Separated installation preparation from activation. Preparation never stops an existing app or service.
- Kept prepared virtual environments at stable runtime paths.
- Preserved the previous app and launch configuration during updates and uninstalls.
- Removed port-based shutdown of unrelated ASR services.

## 0.1.1 - 2026-09-04

### Continuous transcription

- Streamed Sortformer diarization in fixed five-second chunks.
- Limited MLX diarization working memory to 2 GiB and disabled its free-memory cache.
- Added the standard Homebrew paths when the app launches optional transcription tools.
- Updated vulnerable transitive Python dependencies before public release.
- Restricted cloud credential lookup to the process environment and the documented `tts.env` file.

## 0.1.0 - 2026-08-31

First public release.

### Dictation

- Added native Control+Shift push-to-talk dictation.
- Added Option lock mode for long recordings.
- Added recent transcript recovery from the menu bar.
- Added local FluidAudio and Core ML transcription on Apple Silicon.
- Preserved failed and suspiciously quiet audio by default.

### Optional tools

- Added local file and batch transcription with Parakeet MLX.
- Added continuous capture with quick and canonical transcript modes.
- Added optional speaker diarization.
- Added local Supertonic 3 text-to-speech.
- Added explicit Inworld and xAI clipboard TTS integrations.

### Distribution

- Added a prebuilt arm64 release package.
- Removed Homebrew, Python, and Xcode from the core installation path.
- Added separate optional-tool installation.
- Added isolated release verification and privacy scanning.
