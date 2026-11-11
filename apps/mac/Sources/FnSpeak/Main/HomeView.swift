import AVFoundation
import SwiftUI

/// The first thing you see: how to dictate, whether it's working, how much
/// you've used it, and the last few things you said.
struct HomeView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController
    let actions: MainWindowActions

    @ObservedObject private var downloader = ModelDownloader.shared
    @ObservedObject private var upcoming = UpcomingMeetings.shared
    @State private var stats: HistoryStats?
    @State private var recent: [HistoryEntry] = []
    @State private var micGranted = Permission.microphone.state == .allowed
    @State private var axGranted = Permission.accessibility.state == .allowed

    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    /// What most people manage on a keyboard, for the time-saved estimate.
    private static let typingWpm = 40.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                problems
                upNext
                statTiles
                recentSection
                shortcuts
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, Theme.titlebarInset + 8)
            .padding(.bottom, 28)
            .frame(maxWidth: Theme.pageWidth + Theme.gutter * 2)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: reload)
        .onChange(of: engine.historyRevision) { reload() }
        .onChange(of: engine.status) { reload() }
        .onReceive(poll) { _ in
            // Permissions change in System Settings, so keep looking.
            micGranted = Permission.microphone.state == .allowed
            axGranted = Permission.accessibility.state == .allowed
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Text(prefs.triggerStyle == "toggle" ? "Press" : "Hold")
                Keycap(label: keyLabel, size: 20)
                Text("and talk.")
            }
            .font(.system(size: 28, weight: .semibold))

            HStack(spacing: 7) {
                Circle().fill(EngineSummary.color(engine: engine, prefs: prefs)).frame(width: 8, height: 8)
                Text(statusLine).foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
        }
    }

    private var keyLabel: String {
        let name = prefs.hotkey.displayName
        return name == "Fn" ? "fn" : name
    }

    private var statusLine: String {
        if prefs.paused { return "Paused" }
        switch engine.status {
        case .loading: return "Loading the speech model…"
        case .failed: return missingModels.isEmpty ? "Dictation isn't working yet" : "Waiting for the speech model"
        case .ready:
            let speech = prefs.speechEngine == "parakeet" ? "Parakeet" : "Whisper"
            let mode = engine.cleanupWarning == nil ? prefs.mode : "filterOnly"
            let place = mode == "cloud" ? "speech stays on this Mac" : "all on this Mac"
            return "Ready · \(speech) · \(EngineSummary.modeLabel(mode)) · \(place)"
        }
    }

    // MARK: - Problems

    /// Models this setup needs that aren't on disk yet.
    private var missingModels: [(item: ModelDownloader.Item, note: String)] {
        _ = downloader.revision
        var missing: [(ModelDownloader.Item, String)] = []
        if prefs.speechEngine == "parakeet" {
            if !ModelDownloader.Item.parakeet.isPresent { missing.append((.parakeet, "Needed to hear you.")) }
        } else if !ModelDownloader.Item.whisper.isPresent {
            missing.append((.whisper, "Needed to hear you."))
        }
        if prefs.mode == "local", !ModelDownloader.Item.cleanup.isPresent {
            missing.append((.cleanup, "Needed for local cleanup."))
        }
        return missing
    }

    @ViewBuilder private var problems: some View {
        let items = problemItems
        let missing = missingModels
        if !missing.isEmpty {
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(missing.count == 1 ? "One download to go" : "Two downloads to go").fontWeight(.medium)
                    ForEach(missing, id: \.item) { ModelDownloadRow(item: $0.item, note: $0.note) }
                    Text("Models run on this Mac. They're downloaded once and nothing is sent back.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        if !items.isEmpty {
            VStack(spacing: 8) {
                ForEach(items) { item in
                    Card(padding: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.symbol).foregroundStyle(item.tint).frame(width: 18).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).fontWeight(.medium)
                                Text(item.detail).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Button(item.button, action: item.action)
                        }
                    }
                }
            }
        }
    }

    private struct Problem: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        let button: String
        let action: () -> Void
    }

    private var problemItems: [Problem] {
        var items: [Problem] = []
        if !micGranted {
            let mic = Permission.microphone
            items.append(Problem(id: "mic", symbol: "mic.slash.fill", tint: .red, title: "FnSpeak needs the microphone",
                                 detail: mic.why + (mic.state == .off ? " " + mic.settingsHint : ""),
                                 button: mic.actionTitle) { mic.request { micGranted = Permission.microphone.state == .allowed } })
        }
        if !axGranted {
            let ax = Permission.accessibility
            items.append(Problem(id: "ax", symbol: "keyboard", tint: .orange, title: "FnSpeak needs Accessibility",
                                 detail: ax.why + " " + ax.settingsHint,
                                 button: ax.actionTitle) { ax.request() })
        }
        if case .failed(let message) = engine.status, missingModels.isEmpty {
            items.append(Problem(id: "engine", symbol: "exclamationmark.triangle.fill", tint: .red, title: "The speech model didn't load",
                                 detail: message, button: "Models…") { SettingsRouter.shared.tab = .advanced })
        }
        if let warning = engine.cleanupWarning, missingModels.isEmpty {
            items.append(Problem(id: "cleanup", symbol: "wand.and.stars", tint: .orange, title: "Cleanup fell back to the filter",
                                 detail: warning, button: "Cleanup…") { SettingsRouter.shared.tab = .cleanup })
        }
        if prefs.paused {
            items.append(Problem(id: "paused", symbol: "pause.circle.fill", tint: .secondary, title: "Dictation is paused",
                                 detail: "The hotkey does nothing until you resume.", button: "Resume", action: actions.togglePause))
        }
        return items
    }

    // MARK: - Up next

    @ViewBuilder private var upNext: some View {
        if let meeting = upcoming.next {
            Card(padding: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "calendar").foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title).fontWeight(.medium).lineLimit(1)
                        Text(meeting.isNow() ? "On now" : "Starts \(meeting.when())").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let url = meeting.joinURL {
                        Button("Join\(meeting.service.map { " on \($0)" } ?? "")") { NSWorkspace.shared.open(url) }
                        Button("Join and Record") {
                            NSWorkspace.shared.open(url)
                            actions.startMeeting()
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Record", action: actions.startMeeting)
                    }
                }
            }
        }
    }

    // MARK: - Stats

    private var statTiles: some View {
        HStack(spacing: 12) {
            StatTile(value: stats.map { Self.count($0.recentWords) } ?? "–", label: "words this week")
            StatTile(value: pace ?? "–", label: "words a minute")
            StatTile(value: saved ?? "–", label: "saved over typing")
        }
    }

    /// How fast you talk, over the kept history.
    private var pace: String? {
        guard let stats, stats.spokenMs > 5_000, stats.words > 0 else { return nil }
        return String(Int((Double(stats.words) / (Double(stats.spokenMs) / 60_000)).rounded()))
    }

    /// Typing the same words at 40 wpm, minus the time spent saying them.
    private var saved: String? {
        guard let stats, stats.words > 0 else { return nil }
        let minutes = Double(stats.words) / Self.typingWpm - Double(stats.spokenMs) / 60_000
        guard minutes >= 1 else { return minutes > 0 ? "<1 min" : nil }
        return minutes < 90 ? "\(Int(minutes.rounded())) min" : String(format: "%.1f hr", minutes / 60)
    }

    private static func count(_ n: Int64) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !recent.isEmpty {
                    Button("See all") { SettingsRouter.shared.tab = .history }
                        .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                }
            }
            Card(padding: 6) {
                if recent.isEmpty {
                    Text(engine.status == .loading ? "Loading…" : "Your dictations show up here. Try one in any text field.")
                        .foregroundStyle(.secondary)
                        .padding(10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(recent, id: \.id) { HistoryRow(entry: $0, compact: true) }
                    }
                }
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shortcuts").font(.system(size: 13, weight: .semibold))
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(shortcutRows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().padding(.leading, 14) }
                        HStack {
                            Text(row.what)
                            Spacer()
                            if let prefix = row.prefix { Text(prefix).foregroundStyle(.secondary).font(.callout) }
                            Keycap(label: row.key, size: 11.5)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                    }
                }
            }
            HStack(spacing: 14) {
                Button("New note", action: actions.newNote)
                Button("Start a meeting", action: actions.startMeeting)
                Spacer()
                Button("Change the hotkey…") { SettingsRouter.shared.tab = .dictation }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private struct Shortcut { let what: String; let prefix: String?; let key: String }

    private var shortcutRows: [Shortcut] {
        var rows: [Shortcut] = []
        switch prefs.triggerStyle {
        case "toggle":
            rows.append(Shortcut(what: "Start and stop dictating", prefix: "press", key: keyLabel))
        case "hold":
            rows.append(Shortcut(what: "Dictate", prefix: "hold", key: keyLabel))
        default:
            rows.append(Shortcut(what: "Dictate", prefix: "hold", key: keyLabel))
            rows.append(Shortcut(what: "Dictate hands-free", prefix: "double-tap", key: keyLabel))
        }
        if prefs.escapeCancels {
            rows.append(Shortcut(what: "Cancel a dictation", prefix: nil, key: "esc"))
        }
        rows.append(Shortcut(what: "Swap the last dictation for what was heard", prefix: nil, key: "⌃⌥Z"))
        if !prefs.notesHotkey.isModifierOnly {
            rows.append(Shortcut(what: "Quick note", prefix: nil, key: prefs.notesHotkey.displayName))
        }
        return rows
    }

    private func reload() {
        engine.historyStats(recentDays: 7) { stats = $0 }
        engine.history(limit: 5) { recent = $0 }
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}
