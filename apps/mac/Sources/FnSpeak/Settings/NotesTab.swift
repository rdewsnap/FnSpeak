import AppKit
import SwiftUI

struct NotesTab: View {
    @ObservedObject var prefs = Preferences.shared
    @State private var shortcutError: String?
    @State private var exportStatus: String?
    @State private var exporting = false
    @State private var copied: String?

    var body: some View {
        Form {
            Section("Notes bar") {
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
                Picker("Appears", selection: $prefs.notesBarPosition) {
                    Text("Near the pill").tag("pill")
                    Text("Center of the screen").tag("center")
                    Text("Top of the screen").tag("top")
                }
                Toggle("Write titles with the cleanup model", isOn: $prefs.notesAutoTitle)
                Text(prefs.notesAutoTitle
                     ? "A note is saved right away with its first line as the title, then retitled in the background."
                     : "The first line of a note is its title.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Hold the dictation hotkey while the bar is open to dictate into it. Start with **/** or **?** to search. **#words** become tags and lines starting with **- [ ]** become tasks.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Dictations") {
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

            Section("Markdown files") {
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

            Section("AI tools") {
                Text("FnSpeak includes **fnspeak-mcp**, a small MCP server that lets Claude Desktop, Claude Code, Cursor and other MCP clients search your notes, meetings and dictation history. It runs on your Mac, opens your data read-only by default and never uses the network.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Allow AI tools to create notes", isOn: $prefs.mcpAllowWrite)
                Text("Adds **--allow-write** to the setup below. Change it in your client's config if you set it up already.")
                    .font(.callout).foregroundStyle(.secondary)
                if !MCPSetup.isBundled {
                    Text("This build doesn't include fnspeak-mcp at \(MCPSetup.serverPath). Build the app with scripts/build-mac.sh to get it.")
                        .font(.callout).foregroundStyle(.orange)
                }
                snippet("Claude Desktop (claude_desktop_config.json)", MCPSetup.desktopConfig(allowWrite: prefs.mcpAllowWrite), id: "desktop")
                snippet("Claude Code", MCPSetup.claudeCodeCommand(allowWrite: prefs.mcpAllowWrite), id: "code")
            }
        }
        .formStyle(.grouped)
    }

    private func snippet(_ title: String, _ text: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button(copied == id ? "Copied" : "Copy") {
                    Pasteboard.copy(text)
                    copied = id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == id { copied = nil } }
                }
            }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
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

/// How to point an MCP client at the bundled server.
enum MCPSetup {
    static var serverPath: String { Bundle.main.bundlePath + "/Contents/MacOS/fnspeak-mcp" }

    static var isBundled: Bool { FileManager.default.isExecutableFile(atPath: serverPath) }

    static func desktopConfig(allowWrite: Bool) -> String {
        var server: [String: Any] = ["command": serverPath]
        if allowWrite { server["args"] = ["--allow-write"] }
        let config: [String: Any] = ["mcpServers": ["fnspeak": server]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func claudeCodeCommand(allowWrite: Bool) -> String {
        "claude mcp add fnspeak -- \(shellQuoted(serverPath))" + (allowWrite ? " --allow-write" : "")
    }

    private static func shellQuoted(_ text: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+"))
        if text.unicodeScalars.allSatisfy(safe.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
