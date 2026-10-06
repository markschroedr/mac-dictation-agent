# Privacy and data

Mac Dictation Agent processes speech locally by default.

## Local processing

The following workflows run on the Mac:

- Push-to-talk dictation, including microphone plus system-audio dictation.
- Audio and video file transcription.
- Batch transcription.
- Continuous microphone and optional system-audio transcription.
- Speaker diarization.
- Supertonic text-to-speech.

The app has no analytics or telemetry.

## Network requests

The app can make these network requests:

1. It downloads a model when you first use a workflow that needs that model.
2. It sends clipboard text to Inworld when you explicitly select Inworld TTS.
3. It sends clipboard text to xAI when you explicitly select Grok/xAI TTS.

The app does not send microphone audio or transcripts to Inworld or xAI.

## Dictation recovery

The app writes every interactive dictation directly to a durable session directory. Each directory contains ordered WAV chunks and an incremental `transcript.txt`. Mic + System sessions also keep `system-*.wav` chunks:

```txt
~/Library/Application Support/Mac Dictation Agent/recordings/recovery/
```

This includes successful, failed, interrupted, quiet, and empty dictations. The default recovery window is 24 hours. Choose another window under **Settings → Recovery Audio Retention**. The available choices are 24 hours, 7 days, 30 days, and forever. A former explicit **Keep Successful Dictation Audio** preference continues to mean forever until you choose a new window.

Expiry moves complete session directories to macOS Trash. The app excludes active and processing sessions. It does not migrate or prune files in the former `recordings/retained/` or `recordings/successful/` directories.

A process or computer crash can leave the current WAV header incomplete because macOS did not close the audio file. Earlier finalized chunks remain ordinary WAV files. The app does not claim that the current chunk is crash-proof.

## Other local data

Manual file transcripts live in `transcripts/manual-files/`.

Continuous capture stores audio, manifests, and transcripts in `permanent-transcriber/storage/`.

Generated TTS audio lives in `tts-audio/`.

Downloaded models live in `models/`.

Logs live in `logs/`. Hotkey diagnostics record only modifier events from the event tap. They include event and handling times, modifier keycodes and flags, event-source identifiers, state transitions, stop reasons, and dictation session IDs. Paste-request logs include the target process ID and bundle ID, clipboard write result, and physical modifier flags. They do not include transcript text or claim that the target accepted the paste. The app does not log ordinary typed keys.

All paths are below:

```txt
~/Library/Application Support/Mac Dictation Agent/
```

## Credentials

Optional cloud TTS credentials come from the app process environment or live in:

```txt
~/Library/Application Support/Mac Dictation Agent/runtime/tts.env
```

The installer preserves this file during updates. The repository and release package do not contain it.

## Removal

The uninstaller removes the app and LaunchAgent. It keeps Application Support data.

Delete `~/Library/Application Support/Mac Dictation Agent/` manually if you also want to remove transcripts, recordings, models, logs, generated speech, and credentials.
