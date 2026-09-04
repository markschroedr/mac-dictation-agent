# Mac Dictation Agent

![Mac Dictation Agent running as a native macOS menu-bar app](assets/mockups/readme-hero.png)

Speak, release, and your words appear at the cursor. Free, open-source dictation for Apple Silicon Macs. Runs locally. No account.

**[Download for Mac](https://github.com/markschroedr/mac-dictation-agent/releases/latest)** · [Why I built it](https://schroedermark.com/blog/mac-dictation-agent/)

![Illustrated demo: hold the shortcut, speak, then paste the transcript at once](assets/demo/dictation-demo.gif)

## Get started

1. Download the ZIP from the [latest release](https://github.com/markschroedr/mac-dictation-agent/releases/latest) and unzip it.
2. Control-click **Install Mac Dictation Agent.command**, then choose **Open**.
3. Allow Microphone and Accessibility access.
4. Click a text field. Hold **Control+Shift**, speak, then release.

Requires an Apple Silicon Mac running macOS 14 or later. No Homebrew, Python, or Xcode needed for dictation.

The app isn't notarized, so macOS may warn you when opening it. The first use downloads a roughly 460 MB model and can take several minutes to prepare. After that, dictation runs offline.

## Short notes or long thoughts

For a longer recording, hold **Option** before releasing the shortcut. Press **Control+Shift** again to finish.

The app transcribes every 20 seconds while you speak. When you stop, it normally only has the last partial chunk left to process. The finished text appears in one paste. Recent transcripts are available from the menu if you need them again.

On an M4 MacBook Air, a paced 5-minute recording finished about **0.6 seconds after release**. That's the wait for the transcription helper, before the macOS paste. [Measurements and method](docs/BENCHMARKS.md).

![The Mac Dictation Agent menu](assets/screenshots/menu.png)

## How it compares

| | Mac Dictation Agent | [Wispr Flow](https://wisprflow.ai/pricing) | [superwhisper](https://superwhisper.com/docs/get-started/sw-pro) |
| --- | --- | --- | --- |
| Price | Free, MIT | Free tier; paid Pro | Free tier; paid Pro |
| Dictation | Local | Cloud | Local and cloud |
| What you get | A shortcut, local transcription, source you can inspect | Cross-platform apps and AI rewriting | Model choices, modes, and formatting |
| Tradeoff | Manual install, not notarized | Account and internet required | Some models and features require Pro |

## Your words stay on your Mac

Dictation has no analytics or cloud transcription. Transcripts are saved locally. Successful audio is deleted by default; failed or unusually quiet recordings are kept for recovery.

Optional tools add file transcription, continuous recording, speaker labels, and local text-to-speech. Cloud voices are opt-in and send text to the provider you choose.

[Privacy and storage](docs/PRIVACY.md) · [Optional tools and source installation](docs/USAGE.md)

## License

[MIT](LICENSE). See [model and dependency licenses](THIRD_PARTY_NOTICES.md).
