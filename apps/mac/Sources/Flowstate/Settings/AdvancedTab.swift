import SwiftUI

struct AdvancedTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController

    var body: some View {
        Form {
            Picker("Speech engine", selection: $prefs.speechEngine) {
                Text("Whisper (uses your vocabulary while listening)").tag("whisper")
                Text("Parakeet (faster)").tag("parakeet")
            }
            .onChange(of: prefs.speechEngine) { engine.load() }
        }
        .formStyle(.grouped)
    }
}
