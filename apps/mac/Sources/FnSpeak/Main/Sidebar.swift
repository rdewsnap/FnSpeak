import SwiftUI

struct Sidebar: View {
    @ObservedObject var router = SettingsRouter.shared
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController
    let actions: MainWindowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
                Text("FnSpeak").font(Theme.Fonts.heading)
            }
            .padding(.leading, 16)
            .padding(.top, Theme.titlebarInset + 4)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 1) {
                ForEach(SettingsTab.main) { row($0) }
            }
            .padding(.horizontal, 8)

            SetupChecklist()
                .padding(.horizontal, 10)
                .padding(.top, 14)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 1) {
                SidebarRow(title: SettingsTab.integrations.title, symbol: SettingsTab.integrations.symbol, selected: false, external: false) {
                    router.tab = .integrations
                }
                SidebarRow(title: "Settings", symbol: "gearshape", selected: false, external: false) {
                    router.tab = router.settingsPage
                }
                .keyboardShortcut(",", modifiers: .command)
                SidebarRow(title: "Help", symbol: "questionmark.circle", selected: false, external: true) {
                    NSWorkspace.shared.open(AppInfo.helpURL)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            Divider()
            status
        }
        .background(Theme.sunk.ignoresSafeArea())
    }

    private func row(_ tab: SettingsTab) -> some View {
        // History is reached from Home, so Home stays lit while it's open.
        let selected = router.tab == tab || (tab == .home && router.tab == .history)
        return SidebarRow(title: tab.title, symbol: tab.symbol, selected: selected, external: false) {
            router.tab = tab
        }
    }

    /// One line on how things are, at the bottom; clicking goes Home.
    private var status: some View {
        Button { router.tab = .home } label: {
            HStack(spacing: 7) {
                Circle().fill(EngineSummary.color(engine: engine, prefs: prefs)).frame(width: 7, height: 7)
                Text(EngineSummary.short(engine: engine, prefs: prefs))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(AppInfo.version).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("FnSpeak \(AppInfo.version)")
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    /// Opens its own window instead of a page here.
    let external: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSoft)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if external {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0.6)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.14) : Theme.text.opacity(hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The engine's state in words, for the sidebar and Home.
enum EngineSummary {
    static func short(engine: EngineController, prefs: Preferences) -> String {
        if prefs.paused { return "Paused" }
        switch engine.status {
        case .loading: return "Loading…"
        case .failed: return "Needs attention"
        case .ready: return engine.cleanupWarning == nil ? "Ready" : "Ready, filter only"
        }
    }

    static func color(engine: EngineController, prefs: Preferences) -> Color {
        if prefs.paused { return .secondary }
        switch engine.status {
        case .loading: return .yellow
        case .failed: return .red
        case .ready: return engine.cleanupWarning == nil ? .green : .yellow
        }
    }

    static func modeLabel(_ mode: String) -> String {
        switch mode {
        case "local": return "Local cleanup"
        case "cloud": return "Cloud cleanup"
        case "raw": return "Raw"
        default: return "Filter only"
        }
    }
}
