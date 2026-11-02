import AppKit
import SwiftUI

struct ContextTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController
    let indexer: PersonalIndexer

    @State private var accessibilityGranted = ContextReader.requestAccessibility(prompt: false)

    /// Password managers and the like, offered as one-click exclusions.
    private static let suggestions: [(name: String, ids: [String])] = [
        ("1Password", ["com.1password.1password", "com.agilebits.onepassword7"]),
        ("Bitwarden", ["com.bitwarden.desktop"]),
        ("Keychain Access", ["com.apple.keychainaccess"]),
        ("KeePassXC", ["org.keepassxc.keepassxc"]),
        ("Dashlane", ["com.dashlane.dashlanephonefinal"]),
    ]

    var body: some View {
        Form {
            Section("Where names come from") {
                LabeledContent("Projects folder") {
                    HStack {
                        Text(prefs.projectsFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Toggle("Contacts", isOn: $prefs.indexContacts)
                    .onChange(of: prefs.indexContacts) { if prefs.indexContacts { indexer.indexContacts() } }
                Toggle("Calendar", isOn: $prefs.indexCalendar)
                    .onChange(of: prefs.indexCalendar) { if prefs.indexCalendar { indexer.indexCalendar() } }
                HStack {
                    Button("Re-index now", action: indexer.indexAll)
                    Text("Names are matched on this Mac and never uploaded.").font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("On-screen context") {
                Toggle("Read the focused field", isOn: $prefs.readFocusedField)
                Text("Looks at the text just before your cursor so capitalization and names fit what you're writing. Password fields are never read. Needs Accessibility.")
                    .font(.callout).foregroundStyle(.secondary)
                if prefs.readFocusedField && !accessibilityGranted {
                    HStack {
                        Label("Accessibility is off", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Spacer()
                        Button("Grant…") {
                            _ = ContextReader.requestAccessibility(prompt: true)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                accessibilityGranted = ContextReader.requestAccessibility(prompt: false)
                            }
                        }
                    }
                }
            }

            Section("Excluded apps") {
                Text("Flowstate won't listen or read anything while one of these is in front.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(prefs.excludedApps, id: \.self) { bundleId in
                    HStack {
                        AppLabel(bundleId: bundleId)
                        Spacer()
                        Button { prefs.excludedApps.removeAll { $0 == bundleId } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                AddAppMenu(title: "Add app…", excluding: Set(prefs.excludedApps)) { prefs.excludedApps.append($0) }
                let pending = Self.suggestions.filter { suggestion in suggestion.ids.contains { !prefs.excludedApps.contains($0) } }
                if !pending.isEmpty {
                    LabeledContent("Suggested") {
                        HStack {
                            ForEach(pending, id: \.name) { suggestion in
                                Button(suggestion.name) {
                                    for id in suggestion.ids where !prefs.excludedApps.contains(id) { prefs.excludedApps.append(id) }
                                }
                            }
                        }
                    }
                }
            }

            Section("How text is inserted") {
                Text("Pasting works almost everywhere. If an app ignores it, pick another method for that app.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(prefs.insertionOverrides.keys.sorted(), id: \.self) { bundleId in
                    HStack {
                        AppLabel(bundleId: bundleId)
                        Spacer()
                        Picker("", selection: methodBinding(bundleId)) {
                            Text("Accessibility").tag("ax")
                            Text("Type it out").tag("type")
                        }
                        .labelsHidden().fixedSize()
                        Button { prefs.insertionOverrides[bundleId] = nil } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                AddAppMenu(title: "Add app…", excluding: Set(prefs.insertionOverrides.keys)) { prefs.insertionOverrides[$0] = "ax" }
            }
        }
        .formStyle(.grouped)
        .onAppear { accessibilityGranted = ContextReader.requestAccessibility(prompt: false) }
    }

    private func methodBinding(_ bundleId: String) -> Binding<String> {
        Binding(
            get: { prefs.insertionOverrides[bundleId] ?? "ax" },
            set: { prefs.insertionOverrides[bundleId] = $0 }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: prefs.projectsFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.projectsFolder = url.path
        indexer.indexProjects()
    }
}
