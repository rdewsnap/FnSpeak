import AppKit

/// The menu bar icon with a red dot, while a meeting is recording.
enum MeetingStatusBadge {
    static func badge(_ base: NSImage?) -> NSImage? {
        guard let base else { return nil }
        let size = NSSize(width: max(base.size.width, 18), height: max(base.size.height, 18))
        let image = NSImage(size: size, flipped: false) { rect in
            // Drawn at display time, so the icon follows the menu bar's appearance.
            let tinted = NSImage(size: base.size, flipped: false) { r in
                base.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            let origin = NSPoint(x: (rect.width - base.size.width) / 2, y: (rect.height - base.size.height) / 2)
            tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            let dot = NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 6, height: 6)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "FnSpeak (recording a meeting)"
        return image
    }
}
