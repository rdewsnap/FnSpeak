import AppKit
import SwiftUI

/// Looking up and choosing apps by bundle id, for the per-app settings lists.
enum AppLookup {
    static func url(for bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    static func name(for bundleId: String) -> String {
        guard let url = url(for: bundleId) else { return bundleId }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(for bundleId: String) -> NSImage? {
        guard let url = url(for: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Apps with a Dock presence, which are the ones you dictate into.
    static func running() -> [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    @MainActor
    static func chooseFromDisk() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}

/// "Add app" button: running apps first, then any app on disk.
struct AddAppMenu: View {
    let title: String
    let excluding: Set<String>
    let onPick: (String) -> Void

    var body: some View {
        Menu(title) {
            let apps = AppLookup.running().filter { !excluding.contains($0.id) }
            ForEach(apps, id: \.id) { app in
                Button(app.name) { onPick(app.id) }
            }
            if !apps.isEmpty { Divider() }
            Button("Choose from Applications…") {
                if let id = AppLookup.chooseFromDisk() { onPick(id) }
            }
        }
        .fixedSize()
    }
}

/// An app's icon and name, with its bundle id underneath.
struct AppLabel: View {
    let bundleId: String

    var body: some View {
        HStack(spacing: 8) {
            if let icon = AppLookup.icon(for: bundleId) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "app").frame(width: 20, height: 20).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(AppLookup.name(for: bundleId))
                Text(bundleId).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
