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
        window.backgroundColor = Theme.sunkNSColor
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
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
            // The pages sit in a panel under the title bar, which stays put
            // as a header while the page scrolls inside.
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.page)
                .clipShape(Self.panel)
                .overlay(Self.panel.strokeBorder(Theme.line, lineWidth: 1))
                .padding([.trailing, .bottom], Theme.panelMargin)
                .environment(\.inPanel, true)
                // The account button sits right above where a scroll bar would be.
                .scrollIndicators(.never)
        }
        .background(Theme.sunk.ignoresSafeArea())
        .frame(minWidth: 940, minHeight: 560)
        .skinned()
        // The toolbar is there on every page, so the header keeps one
        // height and the close, minimise and zoom buttons stay put.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                AppearanceMenu()
                AccountButton()
            }
        }
    }

    private static let panel = RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)

    @ViewBuilder private var detail: some View {
        switch router.tab {
        case .home:
            HomeView(engine: engine, actions: actions)
        case .history:
            HistoryView(engine: engine)
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
        }
    }
}

/// Light, dark or whatever the Mac is set to, from the top of the window.
private struct AppearanceMenu: View {
    @ObservedObject var prefs = Preferences.shared

    private static let choices: [(value: String, label: String, symbol: String)] = [
        ("system", "System", "circle.lefthalf.filled"),
        ("light", "Light", "sun.max"),
        ("dark", "Dark", "moon"),
    ]

    var body: some View {
        Menu {
            Picker("Appearance", selection: $prefs.appearance) {
                ForEach(Self.choices, id: \.value) { choice in
                    Label(choice.label, systemImage: choice.symbol).tag(choice.value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "sun.max")
        }
        .menuIndicator(.hidden)
        .help("Appearance")
        .accessibilityLabel("Appearance")
    }
}

/// Straight to the Account page in Settings.
private struct AccountButton: View {
    @ObservedObject var account = AccountController.shared

    var body: some View {
        Button { SettingsRouter.shared.tab = .account } label: {
            Image(systemName: account.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
        }
        .help(account.isSignedIn ? (account.email ?? "Account") : "Sign in")
        .accessibilityLabel("Account")
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
        window.backgroundColor = Theme.pageNSColor
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
                    .font(Theme.Fonts.heading)
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
            .background(Theme.sunk)
            Divider()
            Page(title: router.settingsPage.title, subtitle: router.settingsPage.subtitle) {
                SettingsView(tab: router.settingsPage, engine: engine, indexer: indexer)
                    .scrollContentBackground(.hidden)
            }
            .id(router.settingsPage)
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.page)
        }
        .ignoresSafeArea()
        .frame(minWidth: 760, minHeight: 500)
        .skinned()
    }
}
