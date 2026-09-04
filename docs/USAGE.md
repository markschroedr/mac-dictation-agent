# Usage and development

## Long dictation

Hold Control+Shift to record. Hold Option before releasing the shortcut to lock recording. Press Control+Shift again to stop.

The app rotates audio files every 20 seconds and transcribes each completed chunk while recording continues. Transcription runs serially. The app pastes the combined text once recording and all queued transcription finish.

At stop, the app captures another 450 ms to preserve the last word. The helper adds 1 second of silence for final inference. This padding does not add 1 second of waiting.

The last partial chunk is normally under 20 seconds, plus post-roll. This is not a hard latency limit: timer delays, model loading, or a processing backlog can increase the wait.

## Optional tools

The release includes tools for audio/video files, batch transcription, continuous recording, speaker labels, and clipboard text-to-speech.

Install `uv` and `ffmpeg`, then open **Install Optional Tools.command** from the release:

```bash
brew install uv ffmpeg
```

The Python environments use about 1 GB. Models download on first use. Keep roughly 5 GB free for all optional features.

### Continuous transcription

Choose a microphone and mode from the menu, then start continuous transcription.

- **Canonical Only** writes larger durable batches, speaker-labelled variants, and compacted archival audio.
- **Quick + Canonical** also writes smaller provisional batches.

This is separate from hotkey dictation. Its workers wake every 3 seconds and process canonical batches of up to 5 minutes. On shutdown, each worker drains the segments already in its manifest.

Sortformer diarization streams 5-second chunks with a 2 GiB MLX working-memory limit. This is a library limit, not an OS memory sandbox.

Capture data lives in:

```text
~/Library/Application Support/Mac Dictation Agent/permanent-transcriber/storage/
```

### Files and batches

Choose **Transcribe Audio or Video…** from the menu. For a folder:

```bash
bash "$HOME/Library/Application Support/Mac Dictation Agent/runtime/scripts/batch_transcribe.sh" \
  /path/to/audio --output-dir batch-output
```

The command finds common audio formats recursively. It writes `results.json`, `results.jsonl`, and a text file for each input.

### Text-to-speech

- **Supertonic 3** runs locally in English or German.
- **Inworld** and **Grok/xAI** send clipboard text to the selected provider when you start a request.

Put cloud credentials in the installed private file:

```text
~/Library/Application Support/Mac Dictation Agent/runtime/tts.env
```

```bash
INWORLD_API_KEY=...
XAI_API_KEY=...
```

The app also reads these keys from its process environment. The installer preserves `tts.env` during updates.

## Install from source

Requires Apple Command Line Tools, `uv`, and `ffmpeg`:

```bash
git clone https://github.com/markschroedr/mac-dictation-agent.git
cd mac-dictation-agent
brew install uv ffmpeg
bash scripts/install_launch_agent.sh
```

Run the installer again after pulling an update. It stops active workers before replacing the runtime and preserves recordings, transcripts, models, and `tts.env`.

To uninstall:

```bash
bash scripts/uninstall_launch_agent.sh
```

The uninstaller leaves user data in Application Support.

## Development

Hotkey dictation uses FluidAudio's INT8 Core ML Parakeet model. File and continuous transcription use an on-demand MLX worker for media conversion, batch processing, retries, and speaker metadata.

```bash
swift build -c release --package-path swift-agent
bash scripts/run_agent.sh
```

Build and verify a release:

```bash
bash scripts/build_release.sh
bash scripts/verify_release.sh
```

The verifier checks the checksum and ZIP, performs an isolated core install, validates executables and signatures, runs audio-retention and hotkey checks, and scans for private machine paths.

Focused checks live in `scripts/test_*.sh`. Continuous-transcriber checks:

```bash
uv run --project vendor/permanent-transcriber \
  python -m unittest discover -s vendor/permanent-transcriber/tests
```

## Source layout

- `swift-agent/`: menu-bar app, capture, and native dictation helper.
- `asr_worker/`: Parakeet-MLX worker and batch CLI.
- `supertonic_worker/`: local TTS helper.
- `vendor/permanent-transcriber/`: continuous capture, transcription, compaction, and diarization.
- `scripts/`: installation, release, media, and verification.
