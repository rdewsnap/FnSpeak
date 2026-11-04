import Foundation

/// Just enough Markdown → HTML for Apple Notes: headings, paragraphs, bullet,
/// numbered and task lists, bold, italic, inline code and links. Anything
/// else comes through as escaped text.
enum MarkdownHTML {
    static func html(_ markdown: String) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        var list: String?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<div>" + paragraph.map(inline).joined(separator: "<br>") + "</div>")
            paragraph = []
        }
        func closeList() {
            if let tag = list { out.append("</\(tag)>") }
            list = nil
        }
        func openList(_ tag: String) {
            if list == tag { return }
            closeList()
            out.append("<\(tag)>")
            list = tag
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                closeList()
                continue
            }
            if let (level, text) = heading(line) {
                flushParagraph()
                closeList()
                out.append("<h\(level)>\(inline(text))</h\(level)>")
            } else if let (done, text) = task(line) {
                flushParagraph()
                openList("ul")
                out.append("<li>\(done ? "☑" : "☐") \(inline(text))</li>")
            } else if let text = bullet(line) {
                flushParagraph()
                openList("ul")
                out.append("<li>\(inline(text))</li>")
            } else if let text = numbered(line) {
                flushParagraph()
                openList("ol")
                out.append("<li>\(inline(text))</li>")
            } else {
                closeList()
                // Markdown hard breaks ("two spaces") and soft breaks both
                // become line breaks; Notes has no reflowing anyway.
                paragraph.append(line)
            }
        }
        flushParagraph()
        closeList()
        return out.joined(separator: "\n")
    }

    // MARK: - Blocks

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        // Notes only has three heading sizes worth using.
        return (min(hashes, 3), String(line.dropFirst(hashes + 1)))
    }

    private static func task(_ line: String) -> (Bool, String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let rest = line.dropFirst(2)
            if rest.hasPrefix("[ ] ") { return (false, String(rest.dropFirst(4))) }
            if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { return (true, String(rest.dropFirst(4))) }
        }
        return nil
    }

    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { return String(line.dropFirst(2)) }
        return nil
    }

    private static func numbered(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    // MARK: - Inline

    static func inline(_ text: String) -> String {
        var s = escape(text)
        s = replace(s, #"`([^`]+)`"#, "<code>$1</code>")
        s = replace(s, #"\*\*([^*]+)\*\*"#, "<b>$1</b>")
        s = replace(s, #"__([^_]+)__"#, "<b>$1</b>")
        s = replace(s, #"(?<![*\w])\*([^*\s][^*]*)\*(?!\*)"#, "<i>$1</i>")
        s = replace(s, #"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>")
        return s
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
