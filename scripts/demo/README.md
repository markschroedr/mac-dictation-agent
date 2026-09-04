# Demo rendering

The public demo is an explanatory product animation. It shows the normal
hold, speak, release interaction without controlling the desktop or opening
another application.

Run:

```bash
bash scripts/demo/render_isolated_demo.sh
```

The renderer creates MP4, WebM, GIF, and poster assets from one storyboard.
The listening phase is shortened for the illustration. The finishing phase lasts
0.65 seconds, based on the paced helper measurements in
[`docs/BENCHMARKS.md`](../../docs/BENCHMARKS.md). The full sentence appears in
one operation, matching the app's paste behavior. There is no typing animation.
This is not a measurement of the receiving application's paste latency.

Use the normal shortcut for real end-to-end verification. Use the benchmark
script for measured transcription speed. Keep those checks separate from this
animation so the public demo does not claim to be raw screen-recording evidence.

To render different footage through the shared media exporter, run:

```bash
DEMO_START=1.2 DEMO_DURATION=8.5 DEMO_POSTER_AT=7 \
  bash scripts/demo/render_demo.sh assets/demo/raw/dictation-demo.mov
```
