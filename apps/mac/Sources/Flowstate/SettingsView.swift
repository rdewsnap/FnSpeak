import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, dictation, cleanup, vocabulary, context, notes, meetings, privacy, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .cleanup: return "Cleanup"
        case .vocabulary: return "Vocabulary"
        case .context: return "Context"
        case .notes: return "Notes"
        case .meetings: return "Meetings"
        case .privacy: return "Privacy"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "mic"
        case .cleanup: return "wand.and.stars"
        case .vocabulary: return "text.book.closed"
        case .context: return "macwindow"
        case .notes: return "note.text"
        case .meetings: return "person.2.wave.2"
        case .privacy: return "hand.raised"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
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
        tab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settingsTab") ?? "") ?? .general
    }
}

/// Just picks the tab; each tab lives in Settings/.
struct SettingsView: View {
    @ObservedObject var router = SettingsRouter.shared
    @ObservedObject var engine: EngineController
    let indexer: PersonalIndexer

    var body: some View {
        Group {
            switch router.tab {
            case .general: GeneralTab(engine: engine)
            case .dictation: DictationTab()
            case .cleanup: CleanupTab(engine: engine)
            case .vocabulary: VocabularyTab(engine: engine)
            case .context: ContextTab(engine: engine, indexer: indexer)
            case .notes: NotesTab()
            case .meetings: MeetingsTab()
            case .privacy: PrivacyTab(engine: engine)
            case .advanced: AdvancedTab(engine: engine)
            case .about: AboutTab()
            }
        }
        .frame(minWidth: 620, idealWidth: 640, minHeight: 440, idealHeight: 540)
    }
}
