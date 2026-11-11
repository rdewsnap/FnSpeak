import SwiftUI

/// Everything you've dictated that's still kept, newest first, searchable.
struct HistoryView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController
    @State private var entries: [HistoryEntry] = []
    @State private var query = ""
    @State private var loaded = false

    private static let limit = 500

    var body: some View {
        Page(title: "History", subtitle: "Text only, kept on this Mac for \(prefs.historyDays) days. Audio is never saved.") {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search dictations", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 10)

                if entries.isEmpty {
                    empty
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groups, id: \.day) { group in
                                Text(group.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 14).padding(.bottom, 4).padding(.horizontal, 8)
                                ForEach(group.entries, id: \.id) { entry in
                                    HistoryRow(entry: entry, compact: false) { engine.deleteHistoryEntry(entry.id) }
                                }
                            }
                            if entries.count == Self.limit {
                                Text("Showing the latest \(Self.limit). Search to find older ones.")
                                    .font(.caption).foregroundStyle(.tertiary).padding(8)
                            }
                        }
                        .padding(.horizontal, Theme.gutter - 8)
                        .padding(.bottom, 20)
                    }
                }
            }
        }
        .task(id: query) {
            // Wait out fast typing before searching.
            if loaded { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled else { return }
            reload()
        }
        .onChange(of: engine.historyRevision) { reload() }
        .onChange(of: engine.status) { reload() }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: query.isEmpty ? "waveform" : "magnifyingglass")
                .font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(query.isEmpty ? (loaded ? "Nothing dictated yet" : "Loading…") : "No dictations match “\(query)”")
                .foregroundStyle(.secondary)
            if query.isEmpty && loaded {
                Text("Hold \(prefs.hotkey.displayName) in any app and talk.").font(.callout).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    private struct DayGroup { let day: Date; let title: String; let entries: [HistoryEntry] }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.createdAt))) }
        return byDay.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) { title = "Today" }
            else if calendar.isDateInYesterday(day) { title = "Yesterday" }
            else { title = day.formatted(.dateTime.weekday(.wide).month().day()) }
            return DayGroup(day: day, title: title, entries: byDay[day]!.sorted { $0.id > $1.id })
        }
    }

    private func reload() {
        let asked = query
        engine.history(matching: query, limit: Self.limit) { result in
            guard asked == query else { return }
            entries = result
            if engine.isReady { loaded = true }
        }
    }
}

/// One past dictation: where and when, the text, and what you can do with it.
struct HistoryRow: View {
    let entry: HistoryEntry
    /// On Home: two lines at most, and no delete.
    let compact: Bool
    var onDelete: (() -> Void)?

    @State private var hovering = false
    @State private var showRaw = false
    @State private var copied = false

    private var hasRaw: Bool {
        let raw = entry.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !raw.isEmpty && raw != entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon = AppIcons.icon(entry.appId) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "text.cursor").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18, height: 18)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.system(size: 13))
                    .lineLimit(compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if showRaw {
                    Text(entry.raw.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 2) }
                        .help("What the speech model heard, before cleanup")
                }
                Text(caption).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)

            HStack(spacing: 2) {
                if hasRaw && !compact {
                    action(showRaw ? "text.badge.minus" : "text.badge.plus", showRaw ? "Hide what was heard" : "Show what was heard") {
                        showRaw.toggle()
                    }
                }
                action(copied ? "checkmark" : "doc.on.doc", "Copy") {
                    Pasteboard.copy(entry.text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                if let onDelete {
                    action("trash", "Delete this dictation", perform: onDelete)
                }
            }
            .opacity(hovering || copied ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.045 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { Pasteboard.copy(entry.text) }
            if hasRaw { Button("Copy what was heard") { Pasteboard.copy(entry.raw) } }
            if let onDelete {
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }

    private func action(_ symbol: String, _ help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.system(size: 11.5)).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var caption: String {
        let date = Date(timeIntervalSince1970: TimeInterval(entry.createdAt))
        let when = compact
            ? date.formatted(.relative(presentation: .named))
            : date.formatted(date: .omitted, time: .shortened)
        let words = entry.text.split(whereSeparator: \.isWhitespace).count
        var parts = [when]
        if let app = AppIcons.name(entry.appId) { parts.append(app) }
        parts.append("\(words) \(words == 1 ? "word" : "words")")
        return parts.joined(separator: " · ")
    }
}
