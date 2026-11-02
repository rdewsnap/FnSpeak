import SwiftUI

/// Optional Flowstate account: sign in to Flowstate Cloud or your own
/// server. Everything else in Flowstate works the same without one.
struct AccountTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var account = AccountController.shared

    @State private var email = ""
    @State private var pasted = ""
    @State private var ownServer = false
    @State private var serverField = ""

    var body: some View {
        Form {
            serverSection
            if account.isSignedIn {
                signedInSection
            } else {
                signInSection
            }
            if let message = account.error {
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            } else if let notice = account.notice {
                Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
            privacySection
        }
        .formStyle(.grouped)
        .disabled(account.busy)
        .onAppear {
            ownServer = !account.usesCloud
            serverField = account.usesCloud ? "" : prefs.serverURL
            email = prefs.accountEmail ?? ""
            account.refresh()
        }
    }

    // MARK: - Server

    private var serverSection: some View {
        Section {
            Picker("Server", selection: $ownServer) {
                Text("Flowstate Cloud").tag(false)
                Text("My own server").tag(true)
            }
            .pickerStyle(.radioGroup)
            .onChange(of: ownServer) {
                if !ownServer && !account.usesCloud { account.useServer(ServerClient.cloudURL) }
            }
            if ownServer {
                HStack {
                    TextField("Server URL", text: $serverField, prompt: Text("https://flowstate.example.com"))
                        .onSubmit(useOwnServer)
                    Button("Use", action: useOwnServer)
                        .disabled(ServerClient.normalize(serverField) == nil
                                  || ServerClient.normalize(serverField) == ServerClient.normalize(prefs.serverURL))
                }
                Text("Any copy of flowstate-server, such as one you run with Docker. Changing the server signs you out.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Account")
        } footer: {
            Text("An account is optional. It adds sync between Macs, teams with a shared glossary, and hosted cleanup and meeting summaries.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func useOwnServer() {
        account.useServer(serverField)
        if let url = ServerClient.normalize(serverField) { serverField = url.absoluteString }
    }

    // MARK: - Signing in

    @ViewBuilder private var signInSection: some View {
        Section("Sign in") {
            switch account.phase {
            case .waitingForLink(let address):
                Text("We sent a link to **\(address)**. Copy the link from the email and paste it here; there's no need to open it. If you already opened it and pressed **Sign in**, paste the token the page shows instead.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Sign-in link or token", text: $pasted).onSubmit(finish)
                    Button("Sign in", action: finish).disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Button("Send another link") { account.requestLink(email: address) }
                    Button("Use a different email") { account.cancelSignIn() }
                }
            default:
                HStack {
                    TextField("Email", text: $email, prompt: Text("you@example.com"))
                        .textContentType(.emailAddress)
                        .onSubmit { account.requestLink(email: email) }
                    Button("Email me a sign-in link") { account.requestLink(email: email) }
                        .disabled(!email.contains("@"))
                }
                Text("No password: you get a link that works once, for 15 minutes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if account.busy { ProgressView().controlSize(.small) }
        }
    }

    private func finish() {
        account.completeSignIn(pasted: pasted)
        pasted = ""
    }

    // MARK: - Signed in

    private var signedInSection: some View {
        Section("Signed in") {
            LabeledContent("Email", value: account.email ?? "—")
            LabeledContent("Server", value: account.usesCloud ? "Flowstate Cloud" : prefs.serverURL)
            HStack {
                Button("Refresh") { account.refresh() }
                Spacer()
                Button("Sign out", role: .destructive) { account.signOut() }
            }
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section("What is sent") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Signed out, nothing is sent and Flowstate works entirely on this Mac.")
                Text("Signed in, the server gets your email address and, when you use them:")
                Text("• **Audio, never.** Speech is always transcribed on this Mac.")
                Text("• **Notes and meetings** (titles, text, summaries, action items and transcript text) only while **Sync** is on. They're private to you unless you share one with a team.")
                Text("• **Shared items** are readable by every member of that team. Only you can change or delete them.")
                Text("• **Your teams' glossaries** are downloaded into your vocabulary. Nothing from your own vocabulary is uploaded unless you add it to a team's glossary.")
                Text("• **Dictation text** is sent for cleanup only when Cleanup uses Flowstate Cloud (or your server), and **meeting transcripts** for summaries. The server stores token counts, not the text.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
