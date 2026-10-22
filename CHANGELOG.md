# Changelog

## 0.4.1 - 2026-10-22

### Security

- Updated the optional continuous worker's AnyIO dependency from 4.13.0 to 4.14.2, fixing TLS hostname validation and subprocess-security issues.
- Updated Certifi to 2026.10.19 in the Supertonic and continuous-worker environments, removing compromised certificate trust.
- Updated the continuous worker's fsspec dependency to 2026.9.0, fixing unsafe reference-template rendering.

### Speech

- Added local Phonon 40M speech in German and English, with default and male voices. Models download separately and require acceptance of their non-commercial Hugging Face terms.
- Added automatic German/English model selection for local speech while preserving manual language selection.
- Streamed Phonon and xAI PCM directly into one native player, replacing VLC playback.
- Added play/pause, stop, 10-second skip controls, a seekable timeline and 60-second replay access.
- Saved completed app speech as MP3. Stopping playback leaves generation running so the saved recording remains complete.
- Added a local streaming speech endpoint at `/v1/audio/speech`. Other programs receive PCM or WAV without triggering app playback.

### Menu

- Separated transcription, text-to-speech, transcripts and general settings.
- Grouped dictation and continuous recording settings under transcription; kept the model shared.
- Combined recent continuous transcripts into one paged list, preserving existing files and preferring nonempty canonical results over quick results for the same legacy hour.
- Replaced disabled status rows with readable status indicators and refined the player layout.

### Recognition

- Warmed up the transcription model with real inference so macOS can reload evicted Neural Engine weights before dictation.

## 0.3.0 - 2026-10-19

### Updates

- Added daily and manual update checks, with user-selected installation of Ed25519-signed release archives.
- Signed official builds with one stable self-made certificate. The first update from ad-hoc signing requires granting Microphone, Accessibility, and Screen & System Audio Recording permissions again.
- Prepared updates before restarting through a detached installer, preserving the previous runtime for rollback. Active dictation and continuous recording block installation.

### Recognition

- Ran all recognition, including continuous recording and file transcription, on one app-owned FluidAudio model with Parakeet Ultra. Removed the separate MLX worker and the Parakeet v3 and Phonon-2 models.
- Allowed a cold model load up to 600 seconds.

### Continuous recording

- Switched to the current default microphone when the input device stops delivering audio, for example after removing a Bluetooth headset, instead of ending the recording. The gap is kept as silence so both sources stay aligned.
- Ended a recording on digital silence only at startup; a muted microphone no longer stops it.
- Transcribed the saved audio of failed recordings instead of skipping it, and finalized sessions only after all encoders exited.
- Stopped the transcription worker once nothing is pending, so the menu no longer stays in Processing. Start is always available and reuses a worker that is still finishing.
- Kept the original capture error instead of a misleading follow-up error.

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
