import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case home, history, general, dictation, cleanup, vocabulary, snippets, context, notes, meetings, integrations, account, privacy, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .general: return "General"
        case .dictation: return "Dictation"
        case .cleanup: return "Cleanup"
        case .vocabulary: return "Vocabulary"
        case .snippets: return "Snippets"
        case .context: return "Context"
        case .notes: return "Notes"
        case .meetings: return "Meetings"
        case .integrations: return "Integrations"
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
        case .general: return "gearshape"
        case .dictation: return "mic"
        case .cleanup: return "wand.and.stars"
        case .vocabulary: return "text.book.closed"
        case .snippets: return "text.insert"
        case .context: return "macwindow"
        case .notes: return "note.text"
        case .meetings: return "person.2.wave.2"
        case .integrations: return "puzzlepiece.extension"
        case .account: return "person.crop.circle"
        case .privacy: return "hand.raised"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

extension SettingsTab {
    /// The top of the sidebar: what you use, as opposed to what you set once.
    static let main: [SettingsTab] = [.home, .history, .vocabulary, .snippets]
    static let settings: [SettingsTab] = [.general, .dictation, .cleanup, .context, .notes, .meetings, .integrations, .account, .privacy, .advanced, .about]

    /// One line under the page title.
    var subtitle: String? {
        switch self {
        case .home, .history: return nil
        case .snippets: return "Say a snippet's trigger while dictating and its text is typed in its place."
        case .general: return "Startup, where FnSpeak shows up, and the pill."
        case .dictation: return "The hotkey, how it's triggered, and your microphone."
        case .cleanup: return "What tidies the transcript, and how it should write in each app."
        case .vocabulary: return "Names and terms FnSpeak spells your way."
        case .context: return "What FnSpeak reads to get names and tone right."
        case .notes: return "The notes bar and where notes are kept."
        case .meetings: return "Recording, transcripts and summaries."
        case .integrations: return "Apple Notes, webhooks, calendar and Shortcuts."
        case .account: return "Optional. Sync notes and share a glossary with a team."
        case .privacy: return "What stays on this Mac, and what you can delete."
        case .advanced: return "Speech engine, models and troubleshooting."
        case .about: return nil
        }
    }
}

/// Which tab is showing. Shared so one tab can send you to another.
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()

    @Published var tab: SettingsTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") }
    }

    private init() {
        tab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settingsTab") ?? "") ?? .home
    }
}

/// Just picks the page; each one lives in Settings/. Home and History are
/// drawn by the main window itself.
struct SettingsView: View {
    @ObservedObject var router = SettingsRouter.shared
    @ObservedObject var engine: EngineController
    let indexer: PersonalIndexer

    var body: some View {
        Group {
            switch router.tab {
            case .home, .history: EmptyView()
            case .general: GeneralTab(engine: engine)
            case .dictation: DictationTab()
            case .cleanup: CleanupTab(engine: engine)
            case .vocabulary: VocabularyTab(engine: engine)
            case .snippets: SnippetsTab(engine: engine)
            case .context: ContextTab(engine: engine, indexer: indexer)
            case .notes: NotesTab()
            case .meetings: MeetingsTab()
            case .integrations: IntegrationsTab()
            case .account: AccountTab()
            case .privacy: PrivacyTab(engine: engine)
            case .advanced: AdvancedTab(engine: engine)
            case .about: AboutTab()
            }
        }
    }
}
