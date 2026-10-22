import AppKit

/// Read-only status is rendered as status, not a disabled menu command.
@MainActor
final class MenuStatusView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var tint: NSColor = .systemGreen

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
        label.frame = NSRect(x: 32, y: 7, width: 272, height: 18)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("Menu status is created in code") }

    func update(_ text: String, tint: NSColor, detail: String? = nil) {
        label.stringValue = text
        self.tint = tint
        toolTip = detail
        needsDisplay = true
        setAccessibilityLabel(text)
    }

    override func draw(_ dirtyRect: NSRect) {
        tint.setFill()
        NSBezierPath(ovalIn: NSRect(x: 18, y: 13, width: 6, height: 6)).fill()
    }
}

/// The dictation chords are held, not ordinary menu shortcuts. Do not register competing key equivalents.
@MainActor
final class DictationShortcutView: NSView {
    init(title: String, chord: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 27))
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 13)
        label.textColor = .labelColor
        label.frame = NSRect(x: 18, y: 4, width: 224, height: 18)
        let shortcut = NSTextField(labelWithString: chord)
        shortcut.font = .systemFont(ofSize: 12)
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right
        shortcut.frame = NSRect(x: 240, y: 4, width: 62, height: 18)
        addSubview(label)
        addSubview(shortcut)
        toolTip = "Zum Diktieren gedrückt halten; zum Einfügen loslassen."
        setAccessibilityLabel("\(title): \(chord) gedrückt halten")
    }

    required init?(coder: NSCoder) { fatalError("Shortcut hints are created in code") }
}
