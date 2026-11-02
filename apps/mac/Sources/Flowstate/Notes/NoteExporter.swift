import Foundation

/// Mirrors notes into a folder as Markdown files with YAML front matter, so
/// Obsidian and other Markdown tools can read them. Files are named
/// `<title>-<id>.md`; the id keeps the name unique and lets a renamed note
/// replace its old file. Finished meetings can be saved the same way.
enum NoteExporter {
    /// The export folder from settings, or nil when exporting is off.
    static var folder: URL? {
        let path = Preferences.shared.notesExportFolder
        return path.isEmpty ? nil : URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func fileName(for note: Note) -> String {
        "\(safeTitle(note.title))-\(note.id).md"
    }

    /// Where this note's file is (or would be) in the export folder.
    static func fileURL(for note: Note) -> URL? {
        folder?.appendingPathComponent(fileName(for: note))
    }

    static func write(_ note: Note, to folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(for: note))
        try document(for: note).write(to: url, atomically: true, encoding: .utf8)
        // A renamed note leaves its old file behind; remove it.
        for old in files(for: note.id, in: folder) where old.lastPathComponent != url.lastPathComponent {
            try? fm.removeItem(at: old)
        }
    }

    /// Delete a note's file, e.g. after the note was deleted.
    static func remove(id: Int64) {
        guard let folder else { return }
        for url in files(for: id, in: folder) { try? FileManager.default.removeItem(at: url) }
    }

    /// The file's contents: front matter, then the body.
    static func document(for note: Note) -> String {
        var lines = ["---"]
        lines.append("title: \(quoted(note.title.isEmpty ? "Untitled" : note.title))")
        lines.append("created: \(timestamp(note.createdAt))")
        lines.append("updated: \(timestamp(note.updatedAt))")
        if note.tags.isEmpty {
            lines.append("tags: []")
        } else {
            lines.append("tags:")
            lines += note.tags.map { "  - \(quoted($0))" }
        }
        lines.append("source: \(note.source.label)")
        if note.pinned { lines.append("pinned: true") }
        lines.append("flowstate_id: \(note.id)")
        lines.append("---")
        lines.append("")
        let body = note.bodyMd.trimmingCharacters(in: .whitespacesAndNewlines)
        return lines.joined(separator: "\n") + "\n" + body + "\n"
    }

    // MARK: - Meetings

    /// Where finished meetings are saved automatically, or nil when that's off.
    static var meetingFolder: URL? {
        let prefs = Preferences.shared
        guard prefs.meetingAutoExport else { return nil }
        let path = prefs.meetingExportFolder
        return path.isEmpty ? nil : URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// `<date> <title>-meeting-<id>.md`; like notes, the id lets a renamed
    /// meeting replace its old file.
    static func fileName(for meeting: Meeting) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(meeting.startedAt))
        return "\(date.formatted(.iso8601.year().month().day())) \(safeTitle(meeting.title))-meeting-\(meeting.id).md"
    }

    /// Write a meeting's Markdown (from the core's export) with front matter.
    @discardableResult
    static func write(_ meeting: Meeting, markdown: String, to folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(for: meeting))
        try document(for: meeting, markdown: markdown).write(to: url, atomically: true, encoding: .utf8)
        let suffix = "-meeting-\(meeting.id).md"
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasSuffix(suffix) && name != url.lastPathComponent {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        return url
    }

    static func document(for meeting: Meeting, markdown: String) -> String {
        var lines = ["---"]
        lines.append("title: \(quoted(meeting.title.isEmpty ? "Meeting" : meeting.title))")
        lines.append("date: \(timestamp(meeting.startedAt))")
        if let end = meeting.endedAt { lines.append("ended: \(timestamp(end))") }
        if meeting.participants.isEmpty {
            lines.append("participants: []")
        } else {
            lines.append("participants:")
            lines += meeting.participants.map { "  - \(quoted($0))" }
        }
        lines.append("tags:")
        lines.append("  - \"meeting\"")
        lines.append("flowstate_meeting_id: \(meeting.id)")
        lines.append("---")
        lines.append("")
        return lines.joined(separator: "\n") + "\n" + markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - Private

    private static func files(for id: Int64, in folder: URL) -> [URL] {
        let suffix = "-\(id).md"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(suffix) }.map { folder.appendingPathComponent($0) }
    }

    /// A title that's safe as a file name everywhere Obsidian syncs to.
    private static func safeTitle(_ title: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.newlines).union(.controlCharacters)
        var name = title.unicodeScalars.map { banned.contains($0) ? " " : String($0) }.joined()
        name = name.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? "Untitled" : name
    }

    private static func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    private static func timestamp(_ seconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}
