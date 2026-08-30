import AppKit
import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

let candidates = windows.compactMap { window -> (id: Int, bounds: CGRect)? in
    guard let owner = window[kCGWindowOwnerName as String] as? String,
          owner == "MacDictationAgent",
          let layer = window[kCGWindowLayer as String] as? Int,
          layer >= 100,
          let id = window[kCGWindowNumber as String] as? Int,
          let boundsValue = window[kCGWindowBounds as String],
          let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary),
          bounds.width > 200,
          bounds.height > 200 else {
        return nil
    }
    return (id, bounds)
}

guard let menu = candidates.max(by: { $0.id < $1.id }) else {
    exit(1)
}

let scale = NSScreen.main?.backingScaleFactor ?? 1
let values = [menu.bounds.origin.x, menu.bounds.origin.y, menu.bounds.width, menu.bounds.height]
    .map { Int(($0 * scale).rounded()) }
print(values.map(String.init).joined(separator: " "))
