import Foundation

/// Mirrors notes into a folder as Markdown files with YAML front matter, so
/// Obsidian and other Markdown tools can read them. Files are named
/// `<title>-<id>.md`; the id keeps the name unique and lets a renamed note
/// replace its old file.
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
