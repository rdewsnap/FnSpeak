import AppKit
import SwiftUI

struct NotesTab: View {
    @ObservedObject var prefs = Preferences.shared
    @State private var shortcutError: String?
    @State private var exportStatus: String?
    @State private var exporting = false

    var body: some View {
        KitForm {
            KitSection(title: "Notes bar") {
                LabeledContent("Open with") {
                    VStack(alignment: .trailing, spacing: 4) {
                        HotkeyRecorder(hotkey: prefs.notesHotkey) { setShortcut($0) }
                        if let shortcutError {
                            Text(shortcutError).font(.caption).foregroundStyle(.orange)
                        } else if NotesController.conflict(prefs.notesHotkey, dictation: prefs.hotkey) {
                            Text("That's also the dictation hotkey, so it won't open the bar.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                KitPicker("Appears", selection: $prefs.notesBarPosition) {
                    Text("Near the pill").tag("pill")
                    Text("Center of the screen").tag("center")
                    Text("Top of the screen").tag("top")
                }
                Toggle("Start listening when the notes bar opens", isOn: $prefs.notesAutoListen)
                Toggle("Write titles with the cleanup model", isOn: $prefs.notesAutoTitle)
                Text(prefs.notesAutoTitle
                     ? "A note is saved right away with its first line as the title, then retitled in the background."
                     : "The first line of a note is its title.")
                    .font(.callout).foregroundStyle(.secondary)
                // Built from pieces, so it has to be told to read the Markdown.
                Text(.init((prefs.notesAutoListen
                      ? "Open the bar and start talking. Press the shortcut again to stop, or Return to save what you said."
                      : "Hold the dictation hotkey while the bar is open to dictate into it.")
                     + " Start with **/** or **?** to search. **#words** become tags and lines starting with **- [ ]** become tasks."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            KitSection(title: "Dictations") {
                Toggle(isOn: $prefs.saveDictationsAsNotes) {
                    HStack(spacing: 6) {
                        Text("Also save every dictation longer than")
                        TextField("", value: $prefs.dictationNoteMinWords, format: .number)
                            .frame(width: 44)
                            .multilineTextAlignment(.trailing)
                            .disabled(!prefs.saveDictationsAsNotes)
                        Text("words as a note")
                    }
                }
                Text("You can always keep one with **Save last dictation as note** in the menu.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            KitSection(title: "Markdown files") {
                LabeledContent("Export to") {
                    HStack {
                        Text(prefs.notesExportFolder.isEmpty ? "Off" : abbreviated(prefs.notesExportFolder))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                        if !prefs.notesExportFolder.isEmpty {
                            Button("Turn Off") {
                                prefs.notesExportFolder = ""
                                exportStatus = nil
                            }
                        }
                    }
                }
                Text("Each note is kept in sync as **title-id.md** with front matter (title, created, updated, tags, source), ready for Obsidian or any Markdown editor.")
                    .font(.callout).foregroundStyle(.secondary)
                if !prefs.notesExportFolder.isEmpty {
                    HStack {
                        Button("Export All Notes Now") { exportAll() }
                            .disabled(exporting)
                        if exporting { ProgressView().controlSize(.small) }
                        if let exportStatus { Text(exportStatus).font(.callout).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: prefs.notesExportFolder, isDirectory: true))
                        }
                    }
                }
            }
        }
    }

    private func setShortcut(_ hotkey: Hotkey) {
        if hotkey.isModifierOnly {
            shortcutError = "Use a key with modifiers, like ⌥Space."
            return
        }
        shortcutError = nil
        prefs.notesHotkey = hotkey
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for your notes as Markdown files, such as a folder in your Obsidian vault."
        if !prefs.notesExportFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: prefs.notesExportFolder) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.notesExportFolder = url.path
        exportAll()
    }

    private func exportAll() {
        exporting = true
        exportStatus = nil
        NotesStore.shared.exportAll { result in
            exporting = false
            switch result {
            case .success(let count): exportStatus = count == 1 ? "Exported 1 note" : "Exported \(count) notes"
            case .failure(let error): exportStatus = "Couldn't export: \(error.localizedDescription)"
            }
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
