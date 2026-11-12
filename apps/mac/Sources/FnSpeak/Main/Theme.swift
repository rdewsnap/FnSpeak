import AppKit
import SwiftUI

/// Shared pieces of the main window's look: one content width, one card,
/// one keycap.
enum Theme {
    /// Pages are a single column this wide, centered when the window is wider.
    static let pageWidth: CGFloat = 600
    /// Space either side of the column; matches a grouped form's own inset.
    static let gutter: CGFloat = 20
    /// Cards and wells. The kit's medium radius, under its older name.
    static var corner: CGFloat { Radius.medium }
    static let sidebarWidth: CGFloat = 208
    /// Room for the traffic lights above the first row of content.
    static let titlebarInset: CGFloat = 38
}

/// A quiet rounded panel on the window background.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// A key as it looks on the keyboard, for showing a hotkey.
struct Keycap: View {
    let label: String
    var size: CGFloat = 13

    var body: some View {
        Text(label)
            .font(.system(size: size, weight: .medium, design: .rounded))
            .padding(.horizontal, size * 0.55)
            .padding(.vertical, size * 0.22)
            .frame(minWidth: size * 2)
            .background(RoundedRectangle(cornerRadius: size * 0.42, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: size * 0.42, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 0, x: 0, y: 1)
            .accessibilityLabel(label)
    }
}

/// A page in the main window: a title under the title bar, then the content.
struct Page<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Fonts.title)
                if let subtitle {
                    Text(subtitle).font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, Theme.titlebarInset)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: Theme.pageWidth + Theme.gutter * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// App icons by bundle id, looked up once each.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var names: [String: String] = [:]

    static func icon(_ bundleId: String) -> NSImage? {
        if let hit = cache[bundleId] { return hit }
        guard let image = AppLookup.icon(for: bundleId) else { return nil }
        cache[bundleId] = image
        return image
    }

    /// The app's name, or nothing when it isn't installed any more.
    static func name(_ bundleId: String) -> String? {
        if let hit = names[bundleId] { return hit.isEmpty ? nil : hit }
        let name = AppLookup.url(for: bundleId) == nil ? "" : AppLookup.name(for: bundleId)
        names[bundleId] = name
        return name.isEmpty ? nil : name
    }
}
