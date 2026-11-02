import SwiftUI

struct PrivacyTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController

    var body: some View {
        Form {
            Section("History") {
                Stepper("Keep dictation history for \(prefs.historyDays) days", value: $prefs.historyDays, in: 1...365)
                Text("Audio is never saved. Text history stays on this Mac.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
