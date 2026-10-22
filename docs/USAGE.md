# Usage and development

## Menu

- **Transkription:** shared model; dictation shortcuts, microphone and recovery retention; continuous recording controls and sources.
- **Text to Speech:** clipboard speech, voice, language, provider setup and saved audio.
- **Transkripte:** dictations, one continuous recording list, and transcribed files.
- **Allgemein:** sound effects, login startup, updates, diagnostics, the data folder, and model licenses/credits.

Continuous transcript pages combine session transcripts and legacy hourly transcripts without moving files. Legacy canonical and quick outputs for the same hour appear once, preferring a nonempty canonical result. Each page shows 5 entries.

## Long dictation

Hold Control+Shift to record. Hold Option before releasing the shortcut to lock recording. Press Control+Shift again to stop.

The app rotates audio files every 20 seconds and transcribes each completed chunk while recording continues. Transcription runs serially. The app pastes the combined text once recording and all queued transcription finish.

At stop, the app captures another 450 ms to preserve the last word. The helper adds 1 second of silence for final inference. This padding does not add 1 second of waiting.

The last partial chunk is normally under 20 seconds, plus post-roll. This is not a hard latency limit: timer delays, model loading, or a processing backlog can increase the wait.

## Microphone and system audio

Hold Control+Command instead of Control+Shift to record your microphone and the Mac's system audio together, for example both sides of a call. Option locks recording the same way; press Control+Command again to stop.

Both sources are transcribed in 20-second chunks during recording. The pasted text lists timestamped lines labelled `Mic` and `System` in time order. Speech that both sources pick up can appear twice; the app keeps it rather than risk dropping words.

macOS asks for Screen & System Audio Recording permission on first use. If a source fails, the app pastes the available text and keeps the original audio in the recovery directory.

## Sound effects

Start, stop, and error sounds are off by default. Turn them on under **Allgemein → Soundeffekte**.

## Recover a dictation

Choose **Transkription → Rettungsordner öffnen** from the menu. Each session directory contains ordered `chunk-*.wav` files and an incremental `transcript.txt`. The files exist even when transcription returns no text or the app exits before completion.

Choose **Transkription → Audiodatei transkribieren …** to transcribe a recovered chunk manually. The app does not combine or retranscribe recovery chunks automatically.

The app keeps recovery sessions for 24 hours by default. Change the window under **Transkription → Audio aufbewahren**. You can choose 24 hours, 7 days, 30 days, or forever. Expired sessions go to macOS Trash.

A crash can leave the current WAV header incomplete. Earlier finalized chunks remain recoverable. This design reduces loss, but it does not make an in-progress WAV crash-proof or prevent microphone input from stopping.

## Local transcription API

While the app runs, it serves an OpenAI-compatible endpoint on loopback. The endpoint uses the same Core ML Parakeet model as hotkey dictation:

```bash
curl -F file=@recording.m4a http://127.0.0.1:8767/v1/audio/transcriptions
# {"text":"...","duration":3.3}
```

The app accepts formats that CoreAudio reads, such as WAV, AIFF, M4A/MP4 (AAC), MP3, and CAF. It does not accept WebM or Ogg. Uploads are limited to 25 MB. Continuous and file transcription yield to dictation between 20-second recognition windows. `GET /health` reports readiness. Set `MAC_DICTATION_API_PORT` to change the port.

## Optional tools

The release includes tools for audio/video files, batch transcription, continuous recording, speaker labels, and clipboard text-to-speech.

Install `uv` and `ffmpeg`, then open **Install Optional Tools.command** from the release:

```bash
brew install uv ffmpeg
```

The Python environments use about 1 GB. Models download on first use. Keep roughly 5 GB free for all optional features.

### Continuous transcription

Choose a microphone and mode from the menu, then start continuous transcription. Microphone and system audio are included by default. Turn off **Transkription → Systemaudio aufnehmen** before starting when you want microphone-only capture. macOS requests Screen & System Audio Recording permission the first time.

- **Nur Qualität** writes larger durable batches, speaker-labelled variants, and compacted archival audio.
- **Live + Qualität** also writes smaller provisional batches.

Its workers wake every 3 seconds and process canonical batches of up to 5 minutes through the same FluidAudio model as dictation. Choose the model for all workflows under **Transkription → Modell**. Background batches yield between 20-second windows so dictation does not wait behind the backlog. Keep the app running while workers drain. On shutdown, each worker drains the segments already in its manifest.

Sortformer diarization streams 5-second chunks with a 2 GiB MLX working-memory limit. This is a library limit, not an OS memory sandbox.

Capture data lives in:

```text
~/Library/Application Support/Mac Dictation Agent/permanent-transcriber/storage/
```

### Files and batches

Choose **Transkription → Audiodatei transkribieren …** from the menu. For a folder:

```bash
bash "$HOME/Library/Application Support/Mac Dictation Agent/runtime/scripts/batch_transcribe.sh" \
  /path/to/audio --output-dir batch-output
```

Keep the app running. The command finds common audio formats recursively and submits them to its shared FluidAudio service. It writes `results.json`, `results.jsonl`, and a text file for each input. The output directory must be new.

### Text-to-speech

- **Supertonic 3** runs locally in English or German under Open RAIL-M. Its use restrictions apply; disclose machine-generated content when sharing speech.
- **Phonon 40M** runs locally in English or German, with the model's default voice and a named male voice. **Non-commercial use only**, including through the local API. See model access below.
- **Auto** language picks German or English from the text for local voices.
- **Inworld** and **Grok/xAI** send clipboard text to the selected provider when you start a request.

#### Phonon model access

1. Accept the terms for **both** [Phonon 40M DE](https://huggingface.co/gradium/phonon-40m-de) and [Phonon 40M EN](https://huggingface.co/gradium/phonon-40m-en) with your Hugging Face account. Approval is automatic.
2. On each Mac, add a read-access `HF_TOKEN` to the private key file below, or authenticate in Terminal with `uvx --from huggingface_hub hf auth login`.
3. Start Phonon speech. The worker automatically downloads the matching model's weights, config, tokenizer and default voice, plus Henrik/Miles when selected. No manual GGUF download or upload is required.
4. Keep the cached models for later use. App updates preserve local caches but do not transfer weights or Hugging Face credentials between Macs.

Both configured 40M models require access. The public Apache-licensed `phonon-31m-en` is a different model, not this app's configured English model. The catalog voices have a separate Apache-2.0 license; that does not remove the 40M model's non-commercial restriction. See [credits and license links](../THIRD_PARTY_NOTICES.md).

#### Credentials

Put optional cloud credentials or the Hugging Face token in the installed private file:

```text
~/Library/Application Support/Mac Dictation Agent/runtime/tts.env
```

```bash
HF_TOKEN=...
INWORLD_API_KEY=...
XAI_API_KEY=...
```

The app also reads these keys from its process environment. The installer preserves `tts.env` during updates.

#### Playback and recordings

All voices use one native player at the top of the menu: **Play/Pause**, **Stop**, **±10 seconds**, and a seekable timeline.
Phonon and xAI stream PCM directly. Supertonic and Inworld play decoded chunks in text order.
During generation, the timeline covers the audio already received. Seeking and pausing do not interrupt generation.
Stop silences playback without resuming when more audio arrives; generation continues to preserve the complete recording.
Every completed app speech request saves `audio.mp3` from the received PCM for backup and later playback in Recent Audio.
The player shows **Replay** for 60 seconds after playback ends or stops. Pause keeps the player available.
MP3 encoding requires ffmpeg; the temporary PCM recording stays on disk only for the player's lifetime.
API requests below remain audio-only and do not create app recordings.

#### Local streaming speech API

The running app serves Phonon on the same loopback port as transcription. Other programs receive audio; the app does not play API requests.

```bash
curl --fail-with-body http://127.0.0.1:8767/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"model":"phonon","input":"Hallo, das ist ein lokaler Stream.","language":"auto","voice":"male","response_format":"pcm"}' \
  --output speech.pcm

ffplay -f s16le -ar 24000 -ch_layout mono speech.pcm
```

- Model: `phonon` or `phonon-40m`; default: `phonon`. This endpoint does not invoke cloud providers.
- Language: `auto` (default), `de`/`german`, or `en`/`english`.
- Voice: `default` or `male` (Henrik/Miles).
- Format: `pcm` (s16le, mono, 24 kHz) or `wav` (default; streaming header with unknown length).
- Responses use HTTP chunked transfer. WAV consumers must accept unknown RIFF/data lengths.
- A second concurrent Phonon request returns HTTP 429. UI and API share one worker.
- Closing the response cancels that synthesis. Client programs control their own playback.
- A mid-stream failure closes the connection without the final HTTP chunk; clients must treat it as incomplete audio.
- Input: 1–100,000 characters. The worker starts on demand and exits after 300 idle seconds.
- The full input text arrives in one request; this MVP streams audio out, not incremental text in.

## Updates

The app checks GitHub for updates once a day. Choose **Check for Updates…** to check now, then **Update to …** to install and restart. Finish dictation and stop continuous recording first.

The updater verifies the archive's Ed25519 signature before extracting or running its installer. A failed download, signature check, or preparation leaves the current app running. Activation preserves the previous runtime for rollback. Downloads use URLSession, not a browser, and do not add the quarantine attribute.

Official builds use one self-made code-signing certificate. The first update from an ad-hoc build asks for permissions again; later builds keep the same code identity. The app remains unnotarized.

### Release maintainers

Run `bash scripts/setup_release_signing.sh` once. It creates the Ed25519 key pair and code-signing identity in `~/.config/mac-dictation-agent-release/`, using a dedicated keychain. No login keychain or trust settings are changed. Builds temporarily include the dedicated keychain in the search list and restore the previous list.

Back up that **entire directory**, encrypted and offline, including the keychain password. Never regenerate the keys for a normal release. Losing either identity breaks update continuity. The updater's public key must match this release key.

`bash scripts/build_release.sh` creates the ZIP, checksum, and raw 64-byte `.zip.sig` asset. Publish all three together. Without local signing material, contributor builds use ad-hoc signing and cannot produce authenticated updates.

For an isolated update E2E run, build two signed versions and run `bash scripts/verify_update.sh OLD.zip NEW.zip`. It uses a temporary installation and its own launch label. Set `MAC_DICTATION_UPDATE_FEED_URL` only when testing a local feed.

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

All recognition uses one app-owned FluidAudio Core ML model, with Parakeet Ultra as the default. Continuous workers submit local file paths over loopback; they never load their own recognition model. Sortformer remains optional speaker diarization for microphone-only canonical output, not a transcription engine.

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
- `supertonic_worker/`: local TTS helper.
- `phonon_worker/`: local Phonon TTS helper.
- `vendor/permanent-transcriber/`: continuous capture, transcription, compaction, and diarization.
- `scripts/`: installation, release, media, and verification.
