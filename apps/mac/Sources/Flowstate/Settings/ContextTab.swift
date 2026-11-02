import SwiftUI

struct ContextTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController
    let indexer: PersonalIndexer

    var body: some View {
        Form {
            Section("Where names come from") {
                TextField("Projects folder", text: $prefs.projectsFolder)
                Toggle("Contacts", isOn: $prefs.indexContacts)
                Toggle("Calendar", isOn: $prefs.indexCalendar)
                Button("Re-index", action: indexer.indexAll)
            }
        }
        .formStyle(.grouped)
    }
}
