import SwiftUI

/// Optional FnSpeak account: sign in to FnSpeak Cloud or your own
/// server. Everything else in FnSpeak works the same without one.
struct AccountTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var account = AccountController.shared

    @State private var email = ""
    @State private var pasted = ""
    @State private var ownServer = false
    @State private var serverField = ""

    var body: some View {
        KitForm {
            introSection
            if account.isSignedIn {
                signedInSection
                planSection
                SyncSettingsSection()
                TeamsSection()
            } else {
                signInSection
            }
            if let message = account.error {
                KitSection { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            } else if let notice = account.notice {
                KitSection { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
            privacySection
            selfHostedSection
        }
        .disabled(account.busy)
        .onAppear {
            ownServer = !account.usesCloud
            serverField = account.usesCloud ? "" : prefs.serverURL
            email = prefs.accountEmail ?? ""
            account.refresh()
            account.checkSignInProviders()
        }
        // Coming back from a page the plan section opened in the browser.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            account.refresh()
            account.finishGoogleSignIn()
        }
    }

    // MARK: - What an account is

    private var introSection: some View {
        KitSection {
            VStack(alignment: .leading, spacing: 6) {
                Text("An account adds sync between your Macs, teams with a shared glossary, and hosted cleanup and meeting summaries for when you'd rather not run the model here.")
                if !account.usesCloud {
                    Text("Using your own server at \(prefs.serverURL).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Self-hosted server

    /// Out of the way at the bottom: almost nobody runs their own server,
    /// and nobody should have to decide about it before signing in.
    private var selfHostedSection: some View {
        KitSection {
            DisclosureGroup("Use a self-hosted server", isExpanded: $ownServer) {
                HStack {
                    TextField("Server URL", text: $serverField, prompt: Text("https://fnspeak.example.com"))
                        .onSubmit(useOwnServer)
                    Button("Use", action: useOwnServer)
                        .disabled(ServerClient.normalize(serverField) == nil
                                  || ServerClient.normalize(serverField) == ServerClient.normalize(prefs.serverURL))
                }
                Text("For people who run their own copy of fnspeak-server, for example with Docker. Changing the server signs you out.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !account.usesCloud {
                    Button("Go back to FnSpeak Cloud") {
                        account.useServer(ServerClient.cloudURL)
                        serverField = ""
                        ownServer = false
                    }
                }
            }
        }
    }

    private func useOwnServer() {
        account.useServer(serverField)
        if let url = ServerClient.normalize(serverField) { serverField = url.absoluteString }
    }

    // MARK: - Signing in

    @ViewBuilder private var signInSection: some View {
        KitSection(title: "Sign in") {
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
                if account.offersGoogle {
                    Button("Continue with Google") { account.signInWithGoogle() }
                        .buttonStyle(.kitPrimary)
                    Text("Or use your email:")
                        .font(.callout).foregroundStyle(.secondary)
                }
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
        KitSection(title: "Signed in") {
            LabeledContent("Email", value: account.email ?? "—")
            if !account.usesCloud {
                LabeledContent("Server", value: prefs.serverURL)
            }
            HStack {
                Button("Refresh") { account.refresh() }
                Spacer()
                Button("Sign out", role: .destructive) { account.signOut() }
            }
        }
    }

    // MARK: - Plan

    /// Shown only when the server describes a plan. Its words and buttons
    /// come from the server.
    @ViewBuilder private var planSection: some View {
        if let plan = account.plan, let summary = plan.summary {
            KitSection(title: "Plan") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary)
                    if let progress = plan.progress {
                        ProgressView(value: min(max(progress, 0), 1))
                    }
                    if let detail = plan.detail {
                        Text(detail)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(plan.actions ?? []) { action in
                    Button(action.title) { account.open(action) }
                }
            }
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        KitSection(title: "What is sent") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Signed out, nothing is sent and FnSpeak works entirely on this Mac.")
                Text("Signed in, the server gets your email address and, when you use them:")
                Text("• **Audio, never.** Speech is always transcribed on this Mac.")
                Text("• **Notes and meetings** (titles, text, summaries, action items and transcript text) only while **Sync** is on. They're private to you unless you share one with a team.")
                Text("• **Shared items** are readable by every member of that team. Only you can change or delete them.")
                Text("• **Your teams' glossaries** are downloaded into your vocabulary. Nothing from your own vocabulary is uploaded unless you add it to a team's glossary.")
                Text("• **Dictation text** is sent for cleanup only when Cleanup uses FnSpeak Cloud (or your server), and **meeting transcripts** for summaries. The server stores token counts, not the text.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
