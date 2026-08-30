import AppKit
import Foundation

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "AppIcon.iconset")

try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in sizes {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor(calibratedRed: 0.08, green: 0.075, blue: 0.065, alpha: 1.0).setFill()
    NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()

    NSColor(calibratedRed: 0.82, green: 0.80, blue: 0.75, alpha: 1.0).setFill()
    let body = NSRect(x: size * 0.36, y: size * 0.34, width: size * 0.28, height: size * 0.39)
    NSBezierPath(roundedRect: body, xRadius: size * 0.14, yRadius: size * 0.14).fill()

    let stroke = NSBezierPath()
    stroke.lineWidth = max(2, size * 0.055)
    stroke.lineCapStyle = .round
    stroke.move(to: NSPoint(x: size * 0.27, y: size * 0.50))
    stroke.curve(
        to: NSPoint(x: size * 0.73, y: size * 0.50),
        controlPoint1: NSPoint(x: size * 0.27, y: size * 0.24),
        controlPoint2: NSPoint(x: size * 0.73, y: size * 0.24)
    )
    stroke.stroke()

    let stem = NSBezierPath()
    stem.lineWidth = max(2, size * 0.055)
    stem.lineCapStyle = .round
    stem.move(to: NSPoint(x: size * 0.50, y: size * 0.27))
    stem.line(to: NSPoint(x: size * 0.50, y: size * 0.18))
    stem.move(to: NSPoint(x: size * 0.37, y: size * 0.18))
    stem.line(to: NSPoint(x: size * 0.63, y: size * 0.18))
    stem.stroke()

    image.unlockFocus()

    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        fatalError("failed to render \(name)")
    }
    try png.write(to: output.appendingPathComponent(name))
}
