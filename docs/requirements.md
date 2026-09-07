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

## Progressive speech

- Start every speech request with one natural 15-to-30-word chunk.
- Use 40-to-70 words for the second chunk.
- Use larger bounded chunks after the second chunk.
- Apply progressive chunks to every speech provider.
- Play ready chunks in text order through visible VLC controls.
- Do not resume playback after the user stops VLC.
- Save one joined audio file after all chunks finish.
- Do not restart playback when the joined file becomes ready.
- Report monotonic time from generation start to first audio readiness, VLC launch, and observed VLC playback.
- Keep one speech behavior. Do not add fast and slow modes.
