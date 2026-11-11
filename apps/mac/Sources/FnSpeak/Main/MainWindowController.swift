import AppKit
import Combine
import SwiftUI

/// FnSpeak's main window: Home, History, meetings, notes and your words,
/// behind one short sidebar.
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
        window.setContentSize(NSSize(width: 1000, height: 700))
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
    var newNote: () -> Void = {}
    var startMeeting: () -> Void = {}
    /// For the Meetings page; nil only where there's no app around it.
    var meetings: MeetingController?
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
                .ignoresSafeArea()
            Divider().ignoresSafeArea()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        }
        .frame(minWidth: 940, minHeight: 560)
    }

    @ViewBuilder private var detail: some View {
        switch router.tab {
        case .home:
            HomeView(engine: engine, actions: actions).ignoresSafeArea()
        case .history:
            HistoryView(engine: engine).ignoresSafeArea()
        case .notesPage:
            NotesPage()
        case .meetingsPage:
            if let meetings = actions.meetings {
                MeetingsListView(controller: meetings)
            } else {
                Text("Meetings aren't available yet.").foregroundStyle(.secondary)
            }
        default:
            Page(title: router.tab.title, subtitle: router.tab.subtitle) {
                SettingsView(tab: router.tab, engine: engine, indexer: indexer)
                    .scrollContentBackground(.hidden)
            }
            .id(router.tab)
            .ignoresSafeArea()
        }
    }
}

/// Notes inside the main window: the same list and editor as before, on the
/// model the notes bar and the menu already share.
private struct NotesPage: View {
    private let model = NotesController.shared.libraryModel

    var body: some View {
        NotesRootView(model: model)
            .onAppear { model.reload() }
            .onDisappear { model.flush() }
    }
}

/// The settings, in a window of their own: sections down the left, the
/// chosen one on the right.
final class SettingsWindowController: NSWindowController {
    init(engine: EngineController, indexer: PersonalIndexer) {
        let host = NSHostingController(rootView: SettingsWindowView(engine: engine, indexer: indexer))
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 620))
        if !window.setFrameUsingName("FnSpeakSettingsWindow") { window.center() }
        window.setFrameAutosaveName("FnSpeakSettingsWindow")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsWindowView: View {
    @ObservedObject var router = SettingsRouter.shared
    @ObservedObject var engine: EngineController
    let indexer: PersonalIndexer

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 8)
                    .padding(.top, Theme.titlebarInset + 4)
                    .padding(.bottom, 10)
                ForEach(SettingsTab.settings) { tab in
                    SidebarRow(title: tab.title, symbol: tab.symbol, selected: router.settingsPage == tab, external: false) {
                        router.tab = tab
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: 190)
            .background(SidebarBackground())
            Divider()
            Page(title: router.settingsPage.title, subtitle: router.settingsPage.subtitle) {
                SettingsView(tab: router.settingsPage, engine: engine, indexer: indexer)
                    .scrollContentBackground(.hidden)
            }
            .id(router.settingsPage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea()
        .frame(minWidth: 760, minHeight: 500)
    }
}
