import AppKit
import SwiftUI

/// Lays out children left to right, wrapping onto new lines (participant chips).
struct MeetingFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

struct MeetingChip: View {
    let text: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.fill").font(.caption2).foregroundStyle(.secondary)
            Text(text).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove \(text)")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

struct MeetingParticipants: View {
    let names: [String]

    var body: some View {
        if !names.isEmpty {
            MeetingFlowLayout { ForEach(names, id: \.self) { MeetingChip(text: $0) } }
        }
    }
}

/// A horizontal level meter for one audio stream.
struct MeetingLevelBar: View {
    let label: String
    let level: Float
    var active = true

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(active ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: max(4, geo.size.width * CGFloat(active ? level : 0)))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }
}

/// One line of transcript: time, who, and what was said.
struct MeetingSegmentRow: View {
    let segment: Segment

    /// Far-side voices in the order they first spoke. The first keeps the
    /// orange "Others" has always had.
    private static let voiceColors: [Color] = [.orange, .teal, .purple, .pink, .green, .indigo, .brown, .cyan]

    /// One colour per speaker, the same wherever the meeting is shown:
    /// "Speaker 3" is always the third colour, and a name always hashes to
    /// the same one.
    static func color(for speaker: String) -> Color {
        let key = speaker.lowercased()
        if key == "me" { return Theme.accent }
        if key == "others" { return voiceColors[0] }
        if key.hasPrefix("speaker "), let number = Int(key.dropFirst("speaker ".count)), number > 0 {
            return voiceColors[(number - 1) % voiceColors.count]
        }
        // Not hashValue: that changes from launch to launch.
        let sum = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 1_000_003 }
        return voiceColors[sum % voiceColors.count]
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(MeetingController.timestamp(ms: segment.startedMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
            Text(MeetingController.speakerName(segment.speaker))
                .font(.callout.weight(.semibold))
                .foregroundStyle(Self.color(for: segment.speaker))
                .lineLimit(1)
                .frame(width: 74, alignment: .leading)
            Text(segment.text.isEmpty ? segment.raw : segment.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

/// Renders Markdown block by block. `AttributedString(markdown:)` handles
/// the inline styling; SwiftUI's Text would run headings and list items
/// together, so lines are laid out here.
struct MeetingMarkdown: View {
    let markdown: String
    /// Headings whose sections are left out (shown elsewhere).
    var skippingSections: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text, let level):
                    Text(Self.inline(text))
                        .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                        .padding(.top, 6)
                case .bullet(let text, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.inline(text)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case .paragraph(let text):
                    Text(Self.inline(text)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
    }

    private enum Block { case heading(String, Int), bullet(String, Int), paragraph(String) }

    private var blocks: [Block] {
        var blocks: [Block] = []
        var skipping = false
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                skipping = skippingSections.contains { text.localizedCaseInsensitiveContains($0) }
                if !skipping { blocks.append(.heading(text, level)) }
                continue
            }
            if skipping { continue }
            if line.isEmpty { flush(); continue }
            if let marker = ["- [ ] ", "- [x] ", "- ", "* ", "+ "].first(where: { line.hasPrefix($0) }) {
                flush()
                let indent = raw.prefix { $0 == " " || $0 == "\t" }.count / 2
                blocks.append(.bullet(String(line.dropFirst(marker.count)), indent))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
                flush()
                blocks.append(.bullet(line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces), 0))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// A one-line warning with an optional action.
/// Shown where a summary would be, when this Mac has only a cleanup-only
/// model: what's missing, and a button that fetches it.
struct MeetingSummaryModelNotice: View {
    @ObservedObject private var downloader = ModelDownloader.shared

    var body: some View {
        let item = ModelDownloader.Item.cleanup
        VStack(alignment: .leading, spacing: 8) {
            Text("Summaries need the general model. The one on this Mac only tidies dictation.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            switch downloader.state(item) {
            case .downloading(let fraction):
                HStack(spacing: 8) {
                    ProgressView(value: fraction ?? 0).frame(maxWidth: 140)
                    Text(fraction.map { "\(Int($0 * 100))% of \(item.size)" } ?? "Starting…")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Cancel") { downloader.cancel(item) }.controlSize(.small)
                }
            case .unpacking:
                ProgressView().controlSize(.small)
            case .failed(let message):
                Text("Download failed. \(message)").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { downloader.downloadGeneralModel() }.controlSize(.small)
            case .idle:
                Button("Download (\(item.size))") { downloader.downloadGeneralModel() }.controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.12)))
    }
}

extension Meeting {
    /// A summary a model wrote, not the line stored when there was no model to ask.
    var writtenSummary: String? {
        guard let md = summaryMd?.trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty,
              !md.hasPrefix("_Summaries need") else { return nil }
        return md
    }
}

struct MeetingBanner: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    var action: (title: String, run: () -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action { Button(action.title, action: action.run).controlSize(.small) }
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
    }
}

enum MeetingPermissions {
    /// Asks for Screen Recording. The app only shows up in the System Settings
    /// list once it has asked, so this comes first; if the system prompt was
    /// already dismissed once, open the pane so the switch can be flipped.
    static func requestScreenRecording() {
        if CGPreflightScreenCaptureAccess() { return }
        if !CGRequestScreenCaptureAccess() { openScreenRecordingSettings() }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
