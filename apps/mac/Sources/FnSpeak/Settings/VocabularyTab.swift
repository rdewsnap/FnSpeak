import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VocabularyTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController
    @State private var terms: [Term] = []
    @State private var newTerm = ""
    @State private var search = ""
    @State private var filter = "all"
    @State private var notice: String?
    @State private var noticeIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Add a name or term", text: $newTerm).onSubmit(addTerm)
                Button("Add", action: addTerm).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                Picker("", selection: $filter) {
                    Text("All sources").tag("all")
                    ForEach(VocabularySource.allCases) { Text($0.label).tag($0.key) }
                }
                .labelsHidden().fixedSize()
            }

            List {
                ForEach(visible, id: \.text) { term in
                    HStack {
                        Text(term.text)
                        Spacer()
                        SourceBadge(source: term.source)
                        Button {
                            engine.removeTerm(term.text)
                            terms.removeAll { $0.text == term.text }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove \(term.text)")
                    }
                    .contextMenu { TeamGlossaryMenuItems(term: term.text) }
                }
            }
            .overlay {
                if visible.isEmpty {
                    Text(terms.isEmpty ? "No terms yet. Add some, import a list, or point FnSpeak at your projects in Context." : "No matches.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }

            HStack {
                Text("\(terms.count) terms").foregroundStyle(.secondary).font(.callout)
                if let notice {
                    Text(notice).font(.callout).foregroundStyle(noticeIsError ? Color.orange : Color.secondary)
                }
                Spacer()
                Button("Import…", action: importTerms)
                Button("Export…", action: exportTerms).disabled(terms.isEmpty)
            }

            // MARK: Learned vocabulary
            // Learned terms list above with their own badge.
            Toggle("Learn from my corrections", isOn: $prefs.learnFromCorrections)
                .help("When you fix a dictated word, FnSpeak reads back just that text, on this Mac, and remembers the spelling.")
        }
        .padding()
        .onAppear(perform: reload)
    }

    private var visible: [Term] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return terms
            .filter { filter == "all" || $0.source == filter }
            .filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
            .sorted { $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending }
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        engine.addTerms([term], source: .user, replacing: false)
        newTerm = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: reload)
    }

    private func reload() {
        engine.terms { terms = $0 }
    }

    // MARK: - Import and export

    /// One term per line. Blank lines and lines starting with # are skipped.
    private func importTerms() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return show("Couldn't read that file as text.", error: true)
        }
        let existing = Set(terms.map { $0.text.lowercased() })
        let incoming = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && $0.count <= 80 }
        let fresh = Array(Set(incoming)).filter { !existing.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return show("Nothing new in that file.", error: false) }
        engine.addTerms(fresh, source: .user, replacing: false)
        show("Added \(fresh.count) terms.", error: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: reload)
    }

    private func exportTerms() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "fnspeak-vocabulary.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = terms.map(\.text).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.joined(separator: "\n") + "\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            show("Exported \(terms.count) terms.", error: false)
        } catch {
            show("Couldn't write the file.", error: true)
        }
    }

    private func show(_ message: String, error: Bool) {
        notice = message
        noticeIsError = error
    }
}

// MARK: - Source badges

/// Where a term came from. A new source gets a case here to get a badge.
enum VocabularySource: String, CaseIterable, Identifiable {
    case project, contact, calendar, user, correction, learned

    var id: String { rawValue }
    var key: String { rawValue }

    var label: String {
        switch self {
        case .project: return "Projects"
        case .contact: return "Contacts"
        case .calendar: return "Calendar"
        case .user: return "Manual"
        case .correction: return "Corrections"
        case .learned: return "Learned"
        }
    }

    /// Tooltip on the badge, where the source needs explaining.
    var help: String? {
        switch self {
        case .learned: return "Picked up from a word you fixed after dictating"
        default: return nil
        }
    }

    var color: Color {
        switch self {
        case .project: return .blue
        case .contact: return .green
        case .calendar: return .orange
        case .user: return .gray
        case .correction: return .purple
        case .learned: return .accentColor
        }
    }
}

private struct SourceBadge: View {
    let source: String

    var body: some View {
        let known = VocabularySource(rawValue: source)
        Text(known?.label ?? source.capitalized)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(known?.color ?? .gray)
            .background(Capsule().fill((known?.color ?? .gray).opacity(0.15)))
            .help(known?.help ?? "")
    }
}
