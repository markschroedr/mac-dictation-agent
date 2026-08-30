# Privacy and data

Mac Dictation Agent processes speech locally by default.

## Local processing

The following workflows run on the Mac:

- Push-to-talk dictation.
- Audio and video file transcription.
- Batch transcription.
- Continuous microphone transcription.
- Speaker diarization.
- Supertonic text-to-speech.

The app has no analytics or telemetry.

## Network requests

The app can make these network requests:

1. It downloads a model when you first use a workflow that needs that model.
2. It sends clipboard text to Inworld when you explicitly select Inworld TTS.
3. It sends clipboard text to xAI when you explicitly select Grok/xAI TTS.

The app does not send microphone audio or transcripts to Inworld or xAI.

## Dictation retention

The app saves successful dictation transcripts in:

```txt
~/Library/Application Support/Mac Dictation Agent/transcripts/dictation/
```

The app deletes successful dictation audio by default.

The app retains audio when transcription fails. It also retains suspiciously quiet audio. These files help recover speech that the normal path could not transcribe.

Retained audio lives in:

```txt
~/Library/Application Support/Mac Dictation Agent/recordings/retained/
```

Enable **Settings → Retain Successful Dictation Audio** to keep successful recordings. Those files live in:

```txt
~/Library/Application Support/Mac Dictation Agent/recordings/successful/
```

## Other local data

Manual file transcripts live in `transcripts/manual-files/`.

Continuous capture stores audio, manifests, and transcripts in `permanent-transcriber/storage/`.

Generated TTS audio lives in `tts-audio/`.

Downloaded models live in `models/`.

Logs live in `logs/`.

All paths are below:

```txt
~/Library/Application Support/Mac Dictation Agent/
```

## Credentials

Optional cloud TTS credentials live in:

```txt
~/Library/Application Support/Mac Dictation Agent/runtime/tts.env
```

The installer preserves this file during updates. The repository and release package do not contain it.

## Removal

The uninstaller removes the app and LaunchAgent. It keeps Application Support data.

Delete `~/Library/Application Support/Mac Dictation Agent/` manually if you also want to remove transcripts, recordings, models, logs, generated speech, and credentials.
