import AppKit

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
private final class SpeechPlayButton: NSButton {
    var prominent = true { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        // Fixed dark fill + white symbol keep the primary control readable in either menu appearance.
        let fill = prominent ? NSColor(srgbRed: 0.15, green: 0.16, blue: 0.18, alpha: 1)
            : NSColor.quaternaryLabelColor
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: prominent ? bounds.height / 2 : 7,
                     yRadius: prominent ? bounds.height / 2 : 7).fill()
        super.draw(dirtyRect)
    }
}

@MainActor
final class SpeechMenuView: NSView {
    override var isFlipped: Bool { true }
    private let heading = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "")
    private let duration = NSTextField(labelWithString: "")
    private let timeline = SpeechTimeline(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let playButton = SpeechPlayButton()
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
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 170))
        heading.frame = NSRect(x: 18, y: 12, width: 205, height: 18)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .labelColor
        heading.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: 18, y: 33, width: 284, height: 17)
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        state.frame = NSRect(x: 232, y: 13, width: 70, height: 20)
        state.font = .systemFont(ofSize: 10.5, weight: .medium)
        state.alignment = .center
        state.textColor = .systemBlue
        state.wantsLayer = true
        state.layer?.cornerRadius = 10
        for label in [elapsed, duration] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        elapsed.frame = NSRect(x: 18, y: 143, width: 130, height: 17)
        duration.frame = NSRect(x: 172, y: 143, width: 130, height: 17)
        duration.alignment = .right
        timeline.frame = NSRect(x: 16, y: 116, width: 288, height: 22)
        timeline.target = self
        timeline.action = #selector(scrub)
        timeline.isContinuous = false
        timeline.trackFillColor = .systemBlue
        timeline.setAccessibilityLabel("Wiedergabeposition")
        for view in [heading, subtitle, state, elapsed, duration, timeline] { addSubview(view) }
        for (button, frame, symbol, label, action) in [
            (backButton, NSRect(x: 88, y: 64, width: 32, height: 36), "gobackward.10", "10 Sekunden zurück", #selector(back)),
            (playButton, NSRect(x: 140, y: 62, width: 40, height: 40), "play.fill", "Abspielen", #selector(SpeechMenuView.play)),
            (forwardButton, NSRect(x: 200, y: 64, width: 32, height: 36), "goforward.10", "10 Sekunden vor", #selector(forward)),
            (stopButton, NSRect(x: 274, y: 68, width: 28, height: 28), "stop.fill", "Stoppen", #selector(SpeechMenuView.stop))
        ] {
            button.frame = frame
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.isBordered = false
            button.contentTintColor = button === playButton ? .white : .secondaryLabelColor
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("Speech menu is created in code") }

    func refresh(_ value: SpeechPlaybackSnapshot) {
        let compact = value.replay && value.failure == nil
        setFrameSize(NSSize(width: 320, height: compact ? 104 : 170))
        heading.stringValue = value.title
        subtitle.stringValue = value.subtitle + (compact ? " · \(stamp(value.duration))" : "")
        state.stringValue = value.failure != nil ? "Fehler" : value.playing ? "Spielt" : value.replay ? "Fertig" : "Pausiert"
        state.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.10).cgColor
        state.isHidden = compact
        let label = value.playing ? "Pause" : value.replay ? "Erneut abspielen" : "Abspielen"
        playButton.prominent = !compact
        playButton.frame = compact ? NSRect(x: 18, y: 62, width: 284, height: 28)
            : NSRect(x: 140, y: 62, width: 40, height: 40)
        playButton.title = compact ? "Erneut abspielen" : ""
        playButton.imagePosition = compact ? .imageLeading : .imageOnly
        playButton.imageHugsTitle = true
        playButton.contentTintColor = compact ? .labelColor : .white
        playButton.image = NSImage(systemSymbolName: value.playing ? "pause.fill" : value.replay ? "arrow.clockwise" : "play.fill",
                                   accessibilityDescription: label)
        playButton.toolTip = label
        playButton.setAccessibilityLabel(label)
        playButton.isEnabled = value.failure == nil
        for view in [backButton, forwardButton, stopButton, timeline, elapsed, duration] { view.isHidden = compact }
        backButton.isEnabled = value.duration > 0 && value.failure == nil
        forwardButton.isEnabled = backButton.isEnabled
        stopButton.isEnabled = value.playing || !value.replay
        timeline.isEnabled = backButton.isEnabled
        if !timeline.scrubbing {
            timeline.maxValue = max(0.01, value.duration)
            timeline.doubleValue = value.position
        }
        elapsed.stringValue = stamp(value.position)
        duration.stringValue = stamp(value.duration) + (value.generating ? " · wächst" : "")
        toolTip = value.failure
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
