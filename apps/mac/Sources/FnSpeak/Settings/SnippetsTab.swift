import SwiftUI

/// Settings → Snippets: trigger phrases that expand to saved text. The
/// user's own are edited here; team snippets come from sync.
struct SnippetsTab: View {
    @ObservedObject var engine: EngineController
    @ObservedObject private var account = AccountController.shared
    @ObservedObject private var sync = SyncEngine.shared
    @State private var snippets: [Snippet] = []
    @State private var draft: SnippetDraft?
    /// The team snippet awaiting confirmation to be removed.
    @State private var removing: Snippet?

    private var personal: [Snippet] { snippets.filter { !$0.team } }
    private var fromTeams: [Snippet] { snippets.filter(\.team) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snippets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.insert").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("No snippets yet").fontWeight(.medium)
                    Text("Save a phrase like “my calendar link” with the text it stands for.\nSay the phrase in a dictation and the text is typed.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("New Snippet") { draft = SnippetDraft() }
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 60)
            } else {
            HStack {
                Text("\(snippets.count) \(snippets.count == 1 ? "snippet" : "snippets")").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("New Snippet") { draft = SnippetDraft() }
            }

            List {
                Section("Yours") {
                    if personal.isEmpty {
                        Text("None of your own yet.").foregroundStyle(.secondary)
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
                                        removing = snippet
                                    }
                                } else {
                                    Text("Only its author or a team admin can change this")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            }

            if let message = account.error ?? account.notice {
                Text(message).font(.callout).foregroundStyle(account.error == nil ? Color.secondary : Color.orange)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 16)
        .onAppear(perform: reload)
        .onChange(of: sync.snippetsRevision) { reload() }
        .confirmationDialog(
            "Remove “\(removing?.trigger ?? "")” from \(removing?.teamName ?? "the team")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { snippet in
            Button("Remove", role: .destructive) { account.removeTeamSnippet(snippet) }
            Button("Cancel", role: .cancel) {}
        } message: { snippet in
            Text("This removes it for everyone on \(snippet.teamName ?? "the team"), and it can't be undone.")
        }
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
    /// The trigger problem found as you type; blocks Save while it stands.
    @State private var problem: String?
    /// What the last save attempt answered with; cleared by the next edit.
    @State private var saveError: String?
    @State private var saving = false

    private var isTeam: Bool { draft.snippet?.team ?? false }
    private var canSave: Bool {
        problem == nil
            && !saving
            && !draft.trigger.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.snippet == nil ? "New Snippet" : "Edit Snippet").font(.headline)
            TextField("Trigger", text: $draft.trigger, prompt: Text("my calendar link"))
                .onChange(of: draft.trigger) { saveError = nil; check() }
            if let message = problem ?? saveError {
                Text(message).font(.callout).foregroundStyle(.red)
            } else {
                Text("Two or more words you wouldn't say by accident.").font(.callout).foregroundStyle(.secondary)
            }
            TextEditor(text: $draft.text)
                .font(.body)
                .frame(minHeight: 140)
                .border(.separator)
                .onChange(of: draft.text) { saveError = nil }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding()
        .frame(width: 420)
    }

    /// Triggers are checked as you type. A personal trigger is also checked
    /// against the user's other snippets. A team trigger gets the rules that
    /// need no store (two words, not a command, not an everyday phrase), since
    /// every teammate's app drops a team snippet that breaks them; the server
    /// checks the rest on save, since only it knows the team's others.
    private func check() {
        let trigger = draft.trigger
        guard !trigger.trimmingCharacters(in: .whitespaces).isEmpty else { return problem = nil }
        if isTeam { return problem = checkSnippetTrigger(trigger: trigger) }
        engine.snippetTriggerProblem(trigger, ignoring: draft.snippet?.id) { message in
            // Ignore the answer to an older keystroke.
            if trigger == draft.trigger { problem = message }
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        saveError = nil
        let finish: (String?) -> Void = { message in
            saving = false
            if let message {
                saveError = message
            } else {
                saved()
                dismiss()
            }
        }
        if let snippet = draft.snippet, snippet.team {
            AccountController.shared.updateTeamSnippet(snippet, trigger: draft.trigger, text: draft.text, completion: finish)
        } else {
            engine.saveSnippet(id: draft.snippet?.id, trigger: draft.trigger, text: draft.text, completion: finish)
        }
    }
}
