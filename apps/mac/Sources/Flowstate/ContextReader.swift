import AppKit
import ApplicationServices

/// Reads what's on screen right before dictation: the frontmost app, its
/// window title, and the text before the cursor in the focused field.
/// Password fields are never read. Nothing here is stored.
enum ContextReader {
    static func current() -> Context {
        let app = NSWorkspace.shared.frontmostApplication
        var context = Context(
            appId: app?.bundleIdentifier ?? "",
            appName: app?.localizedName ?? "",
            windowTitle: "",
            url: nil,
            textBefore: ""
        )
        guard AXIsProcessTrusted(), let pid = app?.processIdentifier else { return context }

        let appElement = AXUIElementCreateApplication(pid)
        if let window = element(appElement, kAXFocusedWindowAttribute),
           let title = string(window, kAXTitleAttribute) {
            context.windowTitle = title
        }

        let system = AXUIElementCreateSystemWide()
        guard let focused = element(system, kAXFocusedUIElementAttribute) else { return context }
        let role = string(focused, kAXRoleAttribute)
        let subrole = string(focused, kAXSubroleAttribute)
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return context }

        guard let value = string(focused, kAXValueAttribute) else { return context }
        let text = value as NSString
        var cursor = text.length
        if let raw = copy(focused, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(raw as! AXValue, .cfRange, &range) {
                cursor = min(max(range.location, 0), text.length)
            }
        }
        // The core trims this further; cap it so huge documents stay cheap.
        let start = max(0, cursor - 2000)
        context.textBefore = text.substring(with: NSRange(location: start, length: cursor - start))
        return context
    }

    private static func copy(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        copy(element, name) as? String
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = copy(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func requestAccessibility(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
