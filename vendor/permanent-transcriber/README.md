# Permanent Transcriber

Always-on local speech capture and local transcription pipeline.

Current state:

- lightweight microphone capture implemented
- simple conservative WebRTC VAD segmentation
- speech spans persisted as `.opus`
- background workers submit segment batches to the shared Mac Dictation ASR service
- transcripts are written both as structured JSONL and as plain append-only text

## Setup

```bash
cd mac-dictation-agent/vendor/permanent-transcriber
uv venv
uv sync
```

The project has two transcription profiles:

- `quick`: provisional output, small low-latency batches, frequent polling
- `relaxed`: canonical output, larger efficient batches, audio compaction, and speaker diarization

Both use the same captured VAD segments and the app-owned FluidAudio service. The quick profile is optional. The menu calls the `relaxed` profile **Canonical** because that describes its output.

Audio lifecycle:

- capture writes speech segments as Opus at `48k` for transcription
- after a canonical (`relaxed`) transcription succeeds, those segment files are compacted to archival Opus at `24k`
- archived audio is moved to `storage/audio_archive/relaxed/YYYY/MM/DD/HH/`
- compactions are logged in `storage/manifests/audio_compactions.jsonl`

## Run

Use **Start Permanent Transcriber** in the Mac Dictation Agent menu-bar app. The app owns the macOS microphone permission check and only reports recording after the capture process verifies a real nonzero PCM signal.

The CLI remains available from a local permissioned Terminal session. It intentionally refuses capture over SSH because detached remote processes can receive a zero-filled CoreAudio stream while appearing to run normally.

Start background capture + canonical worker locally:

```bash
PERMANENT_TRANSCRIBER_ROOT="$PWD" ./.venv/bin/permanent-transcriber start
```

Start capture with both profile workers:

```bash
PERMANENT_TRANSCRIBER_ROOT="$PWD" ./.venv/bin/permanent-transcriber start --quick
```

Check status:

```bash
PERMANENT_TRANSCRIBER_ROOT="$PWD" ./.venv/bin/permanent-transcriber status
```

The capture status includes `running`, `healthy`, and the most recent startup error. `running: true` without `healthy: true` is never presented as active recording by the menu-bar app.

Stop both:

```bash
PERMANENT_TRANSCRIBER_ROOT="$PWD" ./.venv/bin/permanent-transcriber stop
```

Run capture only in foreground:

```bash
PERMANENT_TRANSCRIBER_ROOT="$PWD" ./.venv/bin/permanent-transcriber run
```

Run worker only in foreground:

```bash
PERMANENT_TRANSCRIBER_ROOT="$PWD" ./.venv/bin/permanent-transcriber worker-run
```

Run profile workers in foreground:

```bash
PERMANENT_TRANSCRIBER_ROOT="$PWD" ./.venv/bin/permanent-transcriber worker-run --profile quick
PERMANENT_TRANSCRIBER_ROOT="$PWD" ./.venv/bin/permanent-transcriber worker-run --profile relaxed
```

Run a bounded one-shot pass:

```bash
PERMANENT_TRANSCRIBER_ROOT="$PWD" ./.venv/bin/permanent-transcriber worker-once --profile relaxed --max-batches 1
PERMANENT_TRANSCRIBER_ROOT="$PWD" ./.venv/bin/permanent-transcriber worker-once --profile quick --max-batches 1
```

## Device Selection

List input devices:

```bash
PERMANENT_TRANSCRIBER_ROOT="$PWD" ./.venv/bin/permanent-transcriber devices
```

Persist a preferred device:

```bash
PERMANENT_TRANSCRIBER_ROOT="$PWD" ./.venv/bin/permanent-transcriber set-device 1
```

Clear the preference:

```bash
PERMANENT_TRANSCRIBER_ROOT="$PWD" ./.venv/bin/permanent-transcriber clear-device
```

Health check:

```bash
PERMANENT_TRANSCRIBER_ROOT="$PWD" ./.venv/bin/permanent-transcriber doctor
```

## ASR

Permanent-transcriber uses the running Mac Dictation Agent on loopback port 8767. Interactive dictation, manual files, quick/canonical batches, and source tracks all share one native FluidAudio model. Workers never start a recognition helper themselves. Keep the app running during capture and shutdown draining.

**Settings → Transcription Model** selects the model for all transcription. Background batches yield to dictation between 20-second recognition windows. Set `MAC_DICTATION_API_PORT` on both the app and workers to isolate test runs.

The active permanent-transcriber package has no Whisper, ONNX, or standalone Parakeet backend route. Historical comparison implementations are not part of the public source release.

## Files

- audio: `storage/audio/YYYY/MM/DD/HH/*.opus`
- canonical archived audio: `storage/audio_archive/relaxed/YYYY/MM/DD/HH/*.opus`
- segment manifest: `storage/manifests/segments.jsonl`
- transcript metadata: `storage/manifests/transcripts.jsonl`
- old pre-profile transcript text: `storage/manifests/transcript_text.log`
- audio compaction metadata: `storage/manifests/audio_compactions.jsonl`
- quick transcript text: `storage/transcripts/quick/YYYY/MM/DD/HH.md`
- canonical transcript text: `storage/transcripts/relaxed/YYYY/MM/DD/HH.md`
- diarized canonical text: `storage/transcripts_diarized/relaxed/YYYY/MM/DD/HH.md`
- capture log: `storage/logs/capture.log`
- worker log: `storage/logs/worker.log`
- shared ASR models: `~/Library/Application Support/Mac Dictation Agent/models/`

## Notes

- active speech is written to a temporary PCM file, not accumulated in RAM
- finalized segments are encoded to Opus through `ffmpeg` at `48k`
- the hour split is only the output folder shard after a VAD segment closes
- the worker simply processes whatever is pending; there is no separate fallback mode
- plain transcript text is appended without metadata, separated by blank lines between completed batches
