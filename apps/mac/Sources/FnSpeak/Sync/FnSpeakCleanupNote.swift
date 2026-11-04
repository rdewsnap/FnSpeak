import SwiftUI

/// Shown in the Cleanup tab in place of the key and model fields when the
/// FnSpeak server is the cloud provider.
struct FnSpeakCleanupNote: View {
    @ObservedObject private var account = AccountController.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        if account.isSignedIn {
            LabeledContent("Account", value: account.email ?? "Signed in")
            Text("Cleanup and meeting summaries run on \(account.usesCloud ? "FnSpeak Cloud" : prefs.serverURL), which picks the model. Only text is sent. If the server can't be reached, dictations fall back to the filter on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack {
                Text("Sign in to use your FnSpeak account for cleanup.").foregroundStyle(.orange)
                Spacer()
                Button("Open Account") { SettingsRouter.shared.tab = .account }
            }
        }
    }
}
