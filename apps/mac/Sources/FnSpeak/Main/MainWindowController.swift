import AppKit
import Combine
import SwiftUI

/// FnSpeak's main window: Home, History, your words, and the settings, behind
/// one sidebar.
final class MainWindowController: NSWindowController {
    private let router = SettingsRouter.shared

    init(engine: EngineController, indexer: PersonalIndexer, actions: MainWindowActions) {
        let root = MainView(engine: engine, indexer: indexer, actions: actions)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "FnSpeak"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 940, height: 680))
        if !window.setFrameUsingName("FnSpeakMain") { window.center() }
        window.setFrameAutosaveName("FnSpeakMain")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(tab: SettingsTab? = nil) {
        if let tab { router.tab = tab }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What the main window can ask the rest of the app to do.
struct MainWindowActions {
    var openNotes: () -> Void = {}
    var newNote: () -> Void = {}
    var openMeetings: () -> Void = {}
    var startMeeting: () -> Void = {}
    var togglePause: () -> Void = {}
}

struct MainView: View {
    @ObservedObject var router = SettingsRouter.shared
    @ObservedObject var engine: EngineController
    let indexer: PersonalIndexer
    let actions: MainWindowActions

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(engine: engine, actions: actions)
                .frame(width: Theme.sidebarWidth)
            Divider().ignoresSafeArea()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea()
        .frame(minWidth: 780, minHeight: 520)
    }

    @ViewBuilder private var detail: some View {
        switch router.tab {
        case .home:
            HomeView(engine: engine, actions: actions)
        case .history:
            HistoryView(engine: engine)
        default:
            Page(title: router.tab.title, subtitle: router.tab.subtitle) {
                SettingsView(engine: engine, indexer: indexer)
                    .scrollContentBackground(.hidden)
            }
            .id(router.tab)
        }
    }
}
