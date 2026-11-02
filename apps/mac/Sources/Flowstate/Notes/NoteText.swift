import Foundation

/// Turns what was typed or dictated into a note: `#tags` become tags, task
/// lines are tidied into Markdown tasks, and the title is left to the core
/// (auto-title) or taken from the first line.
enum NoteText {
    private static let tagPattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_#&/])#([\p{L}][\p{L}\p{N}_\-/]*)"#)
    /// "- [ ]", "-[ ]", "* [ ]", "[]", "[x]" at the start of a line.
    private static let taskPattern = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:[-*+][ \t]*)?\[([ xX]?)\][ \t]*"#, options: [.anchorsMatchLines])

    static func input(from text: String, source: NoteSource, autoTitle: Bool, pinned: Bool = false) -> NoteInput {
        let body = normalizeTasks(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let title = autoTitle ? "" : firstLineTitle(body)
        return NoteInput(title: title, bodyMd: body, source: source, meetingId: nil, tags: tags(in: body), pinned: pinned)
    }

    /// `#tag` words, lowercased, in order of first appearance. Headings
    /// ("# Title") and anchors in links are left alone.
    static func tags(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var result: [String] = []
        for match in tagPattern.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let tag = text[r].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
            if !tag.isEmpty, seen.insert(tag).inserted { result.append(tag) }
        }
        return result
    }

    /// Make every task line a proper `- [ ] ` / `- [x] ` Markdown task.
    static func normalizeTasks(_ text: String) -> String {
        let ns = text as NSString
        var result = text
        for match in taskPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let indent = ns.substring(with: match.range(at: 1))
            let mark = ns.substring(with: match.range(at: 2)).lowercased() == "x" ? "x" : " "
            let replacement = "\(indent)- [\(mark)] "
            guard let r = Range(match.range, in: result) else { continue }
            result.replaceSubrange(r, with: replacement)
        }
        return result
    }

    /// The first non-empty line without Markdown markers, cut to a sensible length.
    static func firstLineTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var title = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- [ ] ", "- [x] ", "- ", "* "] where title.hasPrefix(prefix) {
            title.removeFirst(prefix.count)
        }
        while title.hasPrefix("#") { title.removeFirst() }
        title = title.trimmingCharacters(in: .whitespaces)
        if title.count > 80 { title = String(title.prefix(79)) + "…" }
        return title.isEmpty ? "Untitled" : title
    }

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// Search snippets mark matches with `**bold**`.
    static func highlighted(_ snippet: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: snippet, options: options)) ?? AttributedString(snippet)
    }
}
