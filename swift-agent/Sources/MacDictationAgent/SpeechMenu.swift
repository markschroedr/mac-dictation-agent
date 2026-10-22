import AppKit

/// Keep a user's drag stable while the menu's timer refreshes playback position.
@MainActor
private final class SpeechTimeline: NSSlider {
    var scrubbing = false
    override func mouseDown(with event: NSEvent) {
        scrubbing = true
        defer { scrubbing = false }
        super.mouseDown(with: event)
    }
}

@MainActor
final class SpeechMenuView: NSView {
    private let heading = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let timeline = SpeechTimeline(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let playButton = NSButton()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let stopButton = NSButton()
    private let onPlay: () -> Void
    private let onSeek: (Double) -> Void
    private let onSkip: (Double) -> Void
    private let onStop: () -> Void

    init(play: @escaping () -> Void, seek: @escaping (Double) -> Void,
         skip: @escaping (Double) -> Void, stop: @escaping () -> Void) {
        onPlay = play
        onSeek = seek
        onSkip = skip
        onStop = stop
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 116))
        heading.frame = NSRect(x: 16, y: 91, width: 288, height: 17)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        addSubview(heading)
        time.frame = NSRect(x: 16, y: 5, width: 288, height: 16)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.alignment = .center
        addSubview(time)
        timeline.frame = NSRect(x: 16, y: 24, width: 288, height: 20)
        timeline.target = self
        timeline.action = #selector(scrub)
        timeline.isContinuous = false
        timeline.setAccessibilityLabel("Speech playback position")
        addSubview(timeline)
        for (button, x, symbol, label, action) in [
            (backButton, 78.0, "gobackward.10", "Back 10 seconds", #selector(back)),
            (playButton, 124.0, "play.fill", "Play", #selector(SpeechMenuView.play)),
            (forwardButton, 170.0, "goforward.10", "Forward 10 seconds", #selector(forward)),
            (stopButton, 216.0, "stop.fill", "Stop", #selector(SpeechMenuView.stop))
        ] {
            button.frame = NSRect(x: x, y: 48, width: 30, height: 30)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.isBordered = false
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refresh(_ value: SpeechPlaybackSnapshot) {
        heading.stringValue = value.title + (value.replay ? " · Replay" : "")
        let label = value.playing ? "Pause" : value.replay ? "Replay" : "Play"
        playButton.image = NSImage(systemSymbolName: value.playing ? "pause.fill" : value.replay ? "arrow.clockwise" : "play.fill",
                                   accessibilityDescription: label)
        playButton.toolTip = label
        playButton.setAccessibilityLabel(label)
        playButton.isEnabled = value.failure == nil
        backButton.isEnabled = value.duration > 0 && value.failure == nil
        forwardButton.isEnabled = backButton.isEnabled
        stopButton.isEnabled = value.playing || !value.replay
        timeline.isEnabled = backButton.isEnabled
        if !timeline.scrubbing {
            timeline.maxValue = max(0.01, value.duration)
            timeline.doubleValue = value.position
        }
        let suffix = value.failure != nil ? " · failed" : value.generating ? " · generating" : ""
        time.stringValue = "\(stamp(value.position)) / \(stamp(value.duration))\(suffix)"
        time.toolTip = value.failure
    }

    private func stamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    @objc private func play() { onPlay() }
    @objc private func scrub() { onSeek(timeline.doubleValue) }
    @objc private func back() { onSkip(-10) }
    @objc private func forward() { onSkip(10) }
    @objc private func stop() { onStop() }
}
