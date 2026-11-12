import AppKit
import SwiftUI

/// Setting up fnspeak-mcp, the server that lets AI tools read what
/// FnSpeak keeps on this Mac.
struct MCPTab: View {
    @ObservedObject var prefs = Preferences.shared
    @State private var client = MCPSetup.Client.suggested
    @State private var copied = false
    @State private var notice: String?
    /// Bumped after writing a config, so "Connected" is looked up again.
    @State private var refresh = 0

    var body: some View {
        KitForm {
            KitSection(title: "What it does") {
                Text("FnSpeak includes **fnspeak-mcp**, a small MCP server that lets your AI search your notes, meetings and dictation history. It works with any app that speaks MCP, runs on your Mac, opens your data read-only by default and never uses the network.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            KitSection(title: "Access") {
                Toggle("Allow AI tools to create notes", isOn: $prefs.mcpAllowWrite)
                Text("Adds **--allow-write** to the setup below. Change it in your AI's config if you set it up already.")
                    .font(.callout).foregroundStyle(.secondary)
                if !MCPSetup.isBundled {
                    Text("This build doesn't include fnspeak-mcp at \(MCPSetup.serverPath). Build the app with scripts/build-mac.sh to get it.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            KitSection(title: "Add to your AI") {
                KitPicker("Your AI", selection: $client) {
                    ForEach(MCPSetup.Client.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Status") {
                    HStack {
                        if client.isConnected {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text("Not set up yet").foregroundStyle(.secondary)
                        }
                        if client.canAddForYou && MCPSetup.isBundled {
                            Button(client.isConnected ? "Update" : "Add to \(client.label)") {
                                notice = client.add(allowWrite: prefs.mcpAllowWrite)
                                    ?? "Added. Quit and reopen \(client.label) to see it."
                                refresh += 1
                            }
                        }
                    }
                    .id(refresh)
                }
                if let notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                }
                Text(.init(client.steps))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                snippet(client.snippetTitle, client.snippet(allowWrite: prefs.mcpAllowWrite))
                if let limit = client.limit {
                    Text(limit)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: client) { _, _ in
            notice = nil
            copied = false
        }
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    Pasteboard.copy(text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
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
}

/// How to point an MCP client at the bundled server.
enum MCPSetup {
    static var serverPath: String { Bundle.main.bundlePath + "/Contents/MacOS/fnspeak-mcp" }

    static var isBundled: Bool { FileManager.default.isExecutableFile(atPath: serverPath) }

    /// Some assistant on this Mac is already set up to use the server.
    static var isConnected: Bool { Client.allCases.contains(where: \.isConnected) }

    /// The apps the page has steps for. The server is the same for all of
    /// them; only where its command goes differs.
    enum Client: String, CaseIterable, Identifiable {
        case claudeDesktop, claudeCode, chatgpt, cursor, vscode, windsurf, other

        var id: String { rawValue }

        var label: String {
            switch self {
            case .claudeDesktop: return "Claude Desktop"
            case .claudeCode: return "Claude Code"
            case .chatgpt: return "ChatGPT and Codex"
            case .cursor: return "Cursor"
            case .vscode: return "VS Code"
            case .windsurf: return "Windsurf"
            case .other: return "Something else"
            }
        }

        /// The one already connected, so the page opens on what you use.
        static var suggested: Client { allCases.first(where: \.isConnected) ?? .claudeDesktop }

        /// Where the app keeps its MCP servers, when that's a file we know.
        private var configFile: URL? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claudeDesktop: return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
            case .claudeCode: return home.appendingPathComponent(".claude.json")
            case .chatgpt: return home.appendingPathComponent(".codex/config.toml")
            case .cursor: return home.appendingPathComponent(".cursor/mcp.json")
            case .vscode: return home.appendingPathComponent("Library/Application Support/Code/User/mcp.json")
            case .windsurf: return home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
            case .other: return nil
            }
        }

        var isConnected: Bool {
            guard let configFile, let text = try? String(contentsOf: configFile, encoding: .utf8) else { return false }
            return text.contains("fnspeak-mcp")
        }

        /// FnSpeak can write the config itself: the app is installed and
        /// keeps its servers in a JSON file under `mcpServers`.
        var canAddForYou: Bool {
            guard self == .claudeDesktop || self == .cursor, let configFile else { return false }
            return FileManager.default.fileExists(atPath: configFile.deletingLastPathComponent().path)
        }

        /// What to do with the snippet. Markdown.
        var steps: String {
            switch self {
            case .claudeDesktop:
                return "Use the button, or in Claude Desktop open **Settings → Developer → Edit Config** and add this."
            case .claudeCode:
                return "Run this in Terminal."
            case .chatgpt:
                return "Run this in Terminal if you have the Codex CLI. Or in the ChatGPT desktop app, add an MCP server, choose **STDIO**, and give it the path below as the command."
            case .cursor:
                return "Use the button, or add this to **~/.cursor/mcp.json**."
            case .vscode:
                return "In VS Code, run **MCP: Open User Configuration** from the Command Palette and add this."
            case .windsurf:
                return "In Windsurf, open the MCP settings from the Cascade panel, choose to edit the config, and add this."
            case .other:
                return "Any app that can start a local MCP server works. Give it this as the command; it talks over stdio."
            }
        }

        var snippetTitle: String {
            switch self {
            case .claudeDesktop: return "claude_desktop_config.json"
            case .claudeCode, .chatgpt: return "Terminal"
            case .cursor: return "mcp.json"
            case .vscode: return "mcp.json"
            case .windsurf: return "mcp_config.json"
            case .other: return "Command"
            }
        }

        func snippet(allowWrite: Bool) -> String {
            let command = MCPSetup.shellQuoted(MCPSetup.serverPath) + (allowWrite ? " --allow-write" : "")
            switch self {
            case .claudeDesktop, .cursor, .windsurf: return MCPSetup.json(key: "mcpServers", allowWrite: allowWrite)
            case .vscode: return MCPSetup.json(key: "servers", allowWrite: allowWrite, extra: ["type": "stdio"])
            case .claudeCode: return "claude mcp add fnspeak -- \(command)"
            case .chatgpt: return "codex mcp add fnspeak -- \(command)"
            case .other: return command
            }
        }

        /// Something this app can't do, worth saying before someone goes looking.
        var limit: String? {
            switch self {
            case .chatgpt:
                return "The ChatGPT desktop app, the Codex CLI and the Codex IDE extension share this setup. ChatGPT in a browser or on a phone only connects to servers on the internet, so it can't reach FnSpeak's, which never leaves this Mac."
            default:
                return nil
            }
        }

        /// Add the server to the app's config, keeping everything else in it
        /// and a copy of the file as it was. Returns what went wrong, if anything.
        func add(allowWrite: Bool) -> String? {
            guard canAddForYou, let file = configFile else { return "FnSpeak can't set this one up for you. Paste the snippet in by hand." }
            var config: [String: Any] = [:]
            if let data = try? Data(contentsOf: file), !data.isEmpty {
                guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return "\(label)'s config isn't valid JSON, so it was left alone. Paste the snippet in by hand."
                }
                config = parsed
                try? data.write(to: file.appendingPathExtension("before-fnspeak"))
            }
            var servers = config["mcpServers"] as? [String: Any] ?? [:]
            servers["fnspeak"] = MCPSetup.server(allowWrite: allowWrite)
            config["mcpServers"] = servers
            do {
                let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    private static func server(allowWrite: Bool, extra: [String: Any] = [:]) -> [String: Any] {
        var server: [String: Any] = ["command": serverPath]
        if allowWrite { server["args"] = ["--allow-write"] }
        return server.merging(extra) { current, _ in current }
    }

    private static func json(key: String, allowWrite: Bool, extra: [String: Any] = [:]) -> String {
        let config: [String: Any] = [key: ["fnspeak": server(allowWrite: allowWrite, extra: extra)]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private static func shellQuoted(_ text: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+"))
        if text.unicodeScalars.allSatisfy(safe.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
