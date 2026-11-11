import SwiftUI

/// Settings → Snippets: trigger phrases that expand to saved text. The
/// user's own are edited here; team snippets come from sync.
struct SnippetsTab: View {
    @ObservedObject var engine: EngineController
    @ObservedObject private var account = AccountController.shared
    @ObservedObject private var sync = SyncEngine.shared
    @State private var snippets: [Snippet] = []
    @State private var draft: SnippetDraft?

    private var personal: [Snippet] { snippets.filter { !$0.team } }
    private var fromTeams: [Snippet] { snippets.filter(\.team) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Say a snippet's trigger while dictating and its text is typed in its place.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("New Snippet") { draft = SnippetDraft() }
            }

            List {
                Section("Yours") {
                    if personal.isEmpty {
                        Text("No snippets yet. Try a trigger like “my calendar link”.").foregroundStyle(.secondary)
                    }
                    ForEach(personal, id: \.id) { snippet in
                        row(snippet) {
                            Button("Edit…") { draft = SnippetDraft(snippet) }
                            if account.isSignedIn, !account.sharedTeams.isEmpty {
                                Menu("Share with") {
                                    ForEach(account.sharedTeams) { team in
                                        Button(team.name) { account.shareSnippet(snippet, with: team) }
                                    }
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) { engine.removeSnippet(id: snippet.id, completion: reload) }
                        }
                    }
                }
                if !fromTeams.isEmpty {
                    Section("From your teams") {
                        ForEach(fromTeams, id: \.id) { snippet in
                            row(snippet) {
                                if snippet.canEdit {
                                    Button("Edit…") { draft = SnippetDraft(snippet) }
                                    Button("Remove from \(snippet.teamName ?? "team")", role: .destructive) {
                                        account.removeTeamSnippet(snippet)
                                    }
                                } else {
                                    Text("Only its author or a team admin can change this")
                                }
                            }
                        }
                    }
                }
            }

            if let message = account.error ?? account.notice {
                Text(message).font(.callout).foregroundStyle(account.error == nil ? Color.secondary : Color.orange)
            }
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: sync.snippetsRevision) { reload() }
        .sheet(item: $draft) { draft in
            SnippetEditor(draft: draft, engine: engine, saved: reload)
        }
    }

    private func row<Items: View>(_ snippet: Snippet, @ViewBuilder menu: () -> Items) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.trigger)
                Text(snippet.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if snippet.team {
                Text(snippet.shadowed ? "Replaced by yours" : (snippet.teamName ?? "Team"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Menu(content: menu) { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Actions for \(snippet.trigger)")
        }
    }

    private func reload() {
        engine.snippets { snippets = $0 }
    }
}

/// What the editor sheet is working on: a new snippet, or an existing one.
struct SnippetDraft: Identifiable {
    let id = UUID()
    var snippet: Snippet?
    var trigger = ""
    var text = ""

    init() {}

    init(_ snippet: Snippet) {
        self.snippet = snippet
        trigger = snippet.trigger
        text = snippet.text
    }
}

struct SnippetEditor: View {
    @State var draft: SnippetDraft
    let engine: EngineController
    let saved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    private var isTeam: Bool { draft.snippet?.team ?? false }
    private var canSave: Bool {
        problem == nil
            && !draft.trigger.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.snippet == nil ? "New Snippet" : "Edit Snippet").font(.headline)
            TextField("Trigger", text: $draft.trigger, prompt: Text("my calendar link"))
                .onChange(of: draft.trigger) { check() }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            } else {
                Text("Two or more words you wouldn't say by accident.").font(.callout).foregroundStyle(.secondary)
            }
            TextEditor(text: $draft.text)
                .font(.body)
                .frame(minHeight: 140)
                .border(.separator)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding()
        .frame(width: 420)
    }

    /// Personal triggers are checked as you type. A team snippet's trigger
    /// is checked by the server on save, since only it knows the team's
    /// others; the server doesn't apply the everyday-phrase rule, so an edit
    /// to a team trigger can get past that one.
    private func check() {
        let trigger = draft.trigger
        guard !isTeam, !trigger.trimmingCharacters(in: .whitespaces).isEmpty else { return problem = nil }
        engine.snippetTriggerProblem(trigger, ignoring: draft.snippet?.id) { message in
            // Ignore the answer to an older keystroke.
            if trigger == draft.trigger { problem = message }
        }
    }

    private func save() {
        if let snippet = draft.snippet, snippet.team {
            AccountController.shared.updateTeamSnippet(snippet, trigger: draft.trigger, text: draft.text)
            return dismiss()
        }
        engine.saveSnippet(id: draft.snippet?.id, trigger: draft.trigger, text: draft.text) { message in
            if let message {
                problem = message
            } else {
                saved()
                dismiss()
            }
        }
    }
}
