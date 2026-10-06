# Publication requirements

- Publish the expanded release as `mac-dictation-agent` on GitHub. Do not add `public` to the repository name.
- Keep the README short, clear, and focused on downloading and using the app.
- Keep the existing product media and app comparison.
- Use a short, plain GitHub description.
- Measure long dictation with chunks processed during recording.
- Report the wait after recording stops separately from total recognition time.
- Show the demo transcript appearing in one paste operation.
- Base demo processing time and published speed claims on measured results.

## Consolidation

- Maintain one product codebase for personal use and public releases.
- Preserve personal data and useful features from both repositories.
- Keep private history, credentials, recordings, and runtime data out of GitHub.
- Keep Quick Speak configurable. Do not select a cloud provider automatically for new users.
- Explain optional dependency and credential setup.
- Keep the replacement simple. Use a brief cutover with the previous app available for rollback.
- Archive redundant repositories and runtime folders after verifying the replacement.

## Status menu

- Open the status menu without waiting for filesystem scans or device discovery.
- Load recent transcripts in pages of 5. Load older pages only when requested.
- Keep menu data collection in the background and update menu items on the main thread.

## Continuous recording status

- Show the stop request immediately and prevent a second Stop during shutdown.
- Keep status updates responsive while workers drain saved audio.
- Show processing until canonical and participant transcription jobs finish.

## Continuous source audio

- Preserve microphone and system audio as separate Opus tracks when recording both inputs.
- Keep original source Opus chunks at 48 kbit/s. Do not encode them again after transcription.
- Use the existing permanent worker and shared ASR service for both recording modes.
- Transcribe closed 60-second source chunks during dual-input recording and publish source-labeled transcripts.
- Omit mixed-audio transcription and Sortformer in dual-input mode. Keep the microphone-only path unchanged.
- Drain the final source chunks after Stop and resume unfinished chunks from saved ASR results.
- Use timestamp-bounded fuzzy text matching to remove repeated remote speech from the microphone transcript.
- Preserve additional local speech. Do not require another language model or acoustic echo cancellation.
- Prioritize two-person headphone and loudspeaker calls; defer individual labels for multiple remote speakers.
- Keep processing lightweight and bounded. Reuse the local transcription service.
- Defer optional dual-input direct transcription until the continuous-recording experiment is validated.

## Dual-input dictation

- Keep ordinary microphone-only dictation unchanged.
- Add a separate shortcut for microphone and system-audio dictation.
- Transcribe both sources incrementally through the existing FluidAudio service.
- Combine source-labeled text by timestamps before insertion.
- Prioritize complete text over duplicate removal. Keep possible duplicates in the first version.
- Preserve source audio for recovery and report partial transcription failures.
- Build the change without installing it or restarting the running service.

## Dictation recovery

- Save every interactive dictation directly in a durable session directory.
- Keep ordered audio chunks and the incremental transcript together.
- Use a 24-hour recovery window by default.
- Let the user select 24 hours, 7 days, 30 days, or forever.
- Preserve the former explicit unlimited audio-retention choice as forever.
- Move expired recovery sessions to macOS Trash.
- Never prune an active or processing session.
- Keep legacy diagnostic artifacts unchanged.
- Log modifier-event occurrence time and handling time separately.
- Log only modifier events. Include keycode, raw flags, source details, state action, stop reason, and session correlation.
- Do not change the shortcut state machine without evidence for a specific cause.

## Continuous transcription

- Let the user include or exclude system audio from continuous recording.
- Include microphone and system audio by default.
- Keep selected audio sources separate and combine their timestamped transcripts.
- Do not let the user change audio sources while continuous recording runs.
- Rotate continuous speech into audio segments after 4 minutes.
- Transcribe completed segments while capture continues.

## Progressive speech

- Start every speech request with one natural 15-to-30-word chunk.
- Use 40-to-70 words for the second chunk.
- Grow later chunks progressively to reduce audible boundaries while preserving quick startup.
- Apply progressive chunks to every speech provider.
- Decode ready chunks to one PCM format and stream them in text order through one continuous HTTP audio response.
- Keep visible VLC playback controls. Do not switch player items at generation boundaries.
- Do not resume playback after the user stops VLC.
- Save one joined audio file after all chunks finish.
- Do not restart playback when the joined file becomes ready.
- Report monotonic time from generation start to first audio readiness, VLC launch, and observed VLC playback.
- Keep one speech behavior. Do not add fast and slow modes.

## Deployment

- After a successful activation, keep only the active runtime and the runtime it replaced, with its rollback backup.
- Delete older runtimes and installation backups permanently, not to the Trash.
