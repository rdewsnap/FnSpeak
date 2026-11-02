import SwiftUI

struct DictationTab: View {
    var body: some View {
        Form {
            Section("Hotkeys") {
                Text("Hold **Fn** to talk. Double-tap **Fn** for hands-free, then press Fn to finish.")
                Text("**⌃⌥Z** swaps the last dictation for exactly what you said.")
                Text("If Fn opens the emoji picker, set System Settings → Keyboard → \"Press 🌐 key to\" → Do Nothing.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
