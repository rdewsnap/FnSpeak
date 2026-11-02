import AppKit
import Combine

/// Wires notes into the app: the global shortcut, the notes bar, the Notes
/// window and the menu items. The app delegate owns dictation and hands
/// this the hooks it needs.
final class NotesController: NSObject {
    static let shared = NotesController()

    let bar = NotesBar()
    private let hotkey = NotesHotkey()
    private let prefs = Preferences.shared
    private let store = NotesStore.shared
    private var prefsObserver: AnyCancellable?
    private lazy var window = NotesWindowController()

    /// Call once at launch.
    func start(engine: EngineController, toggleMic: @escaping () -> Void, isListening: @escaping () -> Bool) {
        store.engine = engine
        bar.toggleMic = toggleMic
        bar.isListening = isListening
        bar.onOpenHit = { [weak self] in self?.window.show($0) }
        hotkey.onPress = { [weak self] in self?.bar.toggle() }
        installMainMenu()
        registerHotkey()
        // Settings changes arrive before the new value is stored; look on the next turn.
        prefsObserver = prefs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.registerHotkey() }
    }

    /// Dictated text goes into the bar when it has focus. Returns false otherwise.
    func insertDictation(_ text: String) -> Bool {
        bar.insertDictation(text)
    }

    /// The dictation hotkey and the notes shortcut can't be the same key.
    static func conflict(_ notes: Hotkey, dictation: Hotkey) -> Bool {
        notes == dictation
    }

    private func registerHotkey() {
        let key = prefs.notesHotkey
        if Self.conflict(key, dictation: prefs.hotkey) {
            hotkey.unregister()
            return
        }
        hotkey.register(key)
    }

    // MARK: - Menus

    /// The notes items for the menu bar menu.
    func addMenuItems(to menu: NSMenu) {
        let new = NSMenuItem(title: "New note", action: #selector(newNote), keyEquivalent: "")
        new.target = self
        if !prefs.notesHotkey.isModifierOnly, !Self.conflict(prefs.notesHotkey, dictation: prefs.hotkey) {
            new.toolTip = "Or press \(prefs.notesHotkey.displayName) anywhere"
            new.title = "New note (\(prefs.notesHotkey.displayName))"
        }
        menu.addItem(new)
        let open = NSMenuItem(title: "Notes…", action: #selector(openNotes), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
    }

    /// A Notes menu in the app's main menu, so ⌘⇧N works in any Flowstate window.
    private func installMainMenu() {
        guard let main = NSApp.mainMenu, main.item(withTitle: "Notes") == nil else { return }
        let menu = NSMenu(title: "Notes")
        let open = NSMenuItem(title: "Show Notes", action: #selector(openNotes), keyEquivalent: "n")
        open.keyEquivalentModifierMask = [.command, .shift]
        open.target = self
        menu.addItem(open)
        let new = NSMenuItem(title: "Quick Note", action: #selector(newNote), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        let item = NSMenuItem(title: "Notes", action: nil, keyEquivalent: "")
        item.submenu = menu
        // Before Window, which is last.
        main.insertItem(item, at: max(main.numberOfItems - 1, 0))
    }

    @objc func newNote() {
        bar.show()
    }

    @objc func openNotes() {
        window.show()
    }
}
