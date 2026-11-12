import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case home, history, meetingsPage, notesPage, style, general, dictation, cleanup, vocabulary, snippets, context, notes, meetings, integrations, mcp, account, privacy, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .meetingsPage: return "Meetings"
        case .notesPage: return "Notes"
        case .style: return "Style"
        case .general: return "General"
        case .dictation: return "Dictation"
        case .cleanup: return "Cleanup"
        case .vocabulary: return "Vocabulary"
        case .snippets: return "Snippets"
        case .context: return "Context"
        case .notes: return "Notes"
        case .meetings: return "Meetings"
        case .integrations: return "Connectors"
        case .mcp: return "MCP"
        case .account: return "Account"
        case .privacy: return "Privacy"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .meetingsPage: return "record.circle"
        case .notesPage: return "note.text"
        case .style: return "textformat"
        case .general: return "gearshape"
        case .dictation: return "mic"
        case .cleanup: return "wand.and.stars"
        case .vocabulary: return "text.book.closed"
        case .snippets: return "text.insert"
        case .context: return "macwindow"
        case .notes: return "note.text"
        case .meetings: return "person.2.wave.2"
        case .integrations: return "puzzlepiece.extension"
        case .mcp: return "sparkles"
        case .account: return "person.crop.circle"
        case .privacy: return "hand.raised"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

extension SettingsTab {
    /// The top of the sidebar: what you use, as opposed to what you set once.
    /// History has no row of its own: Home shows the latest and links to the rest.
    static let main: [SettingsTab] = [.home, .meetingsPage, .notesPage, .vocabulary, .snippets, .style]
    static let settings: [SettingsTab] = [.general, .dictation, .cleanup, .context, .notes, .meetings, .integrations, .mcp, .account, .privacy, .advanced, .about]

    /// One line under the page title.
    var subtitle: String? {
        switch self {
        case .home, .history, .meetingsPage, .notesPage: return nil
        case .style: return "How FnSpeak should write in each kind of app."
        case .snippets: return "Say a snippet's trigger while dictating and its text is typed in its place."
        case .general: return "Startup, where FnSpeak shows up, and the pill."
        case .dictation: return "The hotkey, how it's triggered, and your microphone."
        case .cleanup: return "What tidies the transcript after it's heard."
        case .vocabulary: return "Names and terms FnSpeak spells your way."
        case .context: return "What FnSpeak reads to get names and tone right."
        case .notes: return "The notes bar and where notes are kept."
        case .meetings: return "Recording, transcripts and summaries."
        case .integrations: return "Calendars, AI assistants and where your notes can go."
        case .mcp: return "Let your AI search your notes, meetings and dictations."
        case .account: return "Optional. Everything works on this Mac without one."
        case .privacy: return "What stays on this Mac, and what you can delete."
        case .advanced: return "Speech engine, models and troubleshooting."
        case .about: return nil
        }
    }
}

/// What's showing where. The main window has the pages you use; the
/// settings live in a window of their own. Setting `tab` to either kind goes
/// to the right window, so any view can send you anywhere.
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()

    /// The page in the main window.
    @Published private(set) var page: SettingsTab = .home
    /// The page in the settings window.
    @Published private(set) var settingsPage: SettingsTab {
        didSet { UserDefaults.standard.set(settingsPage.rawValue, forKey: "settingsTab") }
    }

    /// Set by the app: bring up the settings window.
    var openSettingsWindow: (() -> Void)?

    var tab: SettingsTab {
        get { page }
        set {
            if SettingsTab.settings.contains(newValue) {
                settingsPage = newValue
                openSettingsWindow?()
            } else {
                page = newValue
            }
        }
    }

    private init() {
        let saved = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settingsTab") ?? "")
        settingsPage = saved.flatMap { SettingsTab.settings.contains($0) ? $0 : nil } ?? .general
    }
}

/// Just picks the page; each one lives in Settings/. Home, History, Notes
/// and Meetings are drawn by the main window itself.
struct SettingsView: View {
    let tab: SettingsTab
    @ObservedObject var engine: EngineController
    let indexer: PersonalIndexer

    var body: some View {
        Group {
            switch tab {
            case .home, .history, .meetingsPage, .notesPage: EmptyView()
            case .style: StyleTab()
            case .general: GeneralTab(engine: engine)
            case .dictation: DictationTab()
            case .cleanup: CleanupTab(engine: engine)
            case .vocabulary: VocabularyTab(engine: engine)
            case .snippets: SnippetsTab(engine: engine)
            case .context: ContextTab(engine: engine, indexer: indexer)
            case .notes: NotesTab()
            case .meetings: MeetingsTab()
            case .integrations: ConnectorsTab()
            case .mcp: MCPTab()
            case .account: AccountTab()
            case .privacy: PrivacyTab(engine: engine)
            case .advanced: AdvancedTab(engine: engine)
            case .about: AboutTab()
            }
        }
    }
}
