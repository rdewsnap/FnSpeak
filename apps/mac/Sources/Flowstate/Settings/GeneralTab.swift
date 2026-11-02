import SwiftUI

struct GeneralTab: View {
    @ObservedObject var engine: EngineController

    var body: some View {
        Form {
            Section("Status") {
                switch engine.status {
                case .loading: Text("Loading the speech model…").foregroundStyle(.secondary)
                case .ready: Text("Ready").foregroundStyle(.secondary)
                case .failed(let message): Text(message).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}
