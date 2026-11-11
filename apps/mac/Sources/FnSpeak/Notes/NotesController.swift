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
    private var dictationObserver: AnyCancellable?
    /// Dictations already kept as notes, so they aren't saved twice.
    private var savedDictations = Set<UUID>()
    private lazy var window = NotesWindowController()

    /// Call once at launch.
    func start(engine: EngineController, toggleMic: @escaping () -> Void, isListening: @escaping () -> Bool) {
        store.engine = engine
        bar.toggleMic = toggleMic
        bar.isListening = isListening
        bar.onOpenHit = { [weak self] hit in
            guard let self else { return }
            guard let showLibrary = self.showLibrary else { return self.window.show(hit) }
            self.libraryModel.reload()
            self.libraryModel.select(hit)
            showLibrary()
        }
        hotkey.onPress = { [weak self] in self?.bar.toggle() }
        installMainMenu()
        registerHotkey()
        // Settings changes arrive before the new value is stored; look on the next turn.
        prefsObserver = prefs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.registerHotkey() }
        dictationObserver = RecentDictations.shared.$items
            .compactMap(\.first)
            .removeDuplicates { $0.id == $1.id }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.dictated($0) }
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
        let last = NSMenuItem(title: "Save last dictation as note", action: nil, keyEquivalent: "")
        if let item = RecentDictations.shared.items.first, !savedDictations.contains(item.id) {
            last.action = #selector(saveLastDictation)
            last.target = self
        }
        menu.addItem(last)
        menu.addItem(.separator())
    }

    /// A Notes menu in the app's main menu, so ⌘⇧N works in any FnSpeak window.
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

    /// The list and selection behind the Notes page.
    var libraryModel: NotesWindowModel { window.model }

    /// Set by the app: show the Notes page in the main window.
    var showLibrary: (() -> Void)?

    @objc func openNotes() {
        guard let showLibrary else { return window.show() }
        libraryModel.reload()
        showLibrary()
    }

    @objc func saveLastDictation() {
        guard let item = RecentDictations.shared.items.first else { return }
        save(item)
    }

    // MARK: - Dictation to note

    /// With the setting on, long dictations are kept as notes as well.
    private func dictated(_ item: RecentDictations.Item) {
        guard prefs.saveDictationsAsNotes,
              NoteText.wordCount(item.text) >= max(prefs.dictationNoteMinWords, 1) else { return }
        save(item)
    }

    private func save(_ item: RecentDictations.Item) {
        guard savedDictations.insert(item.id).inserted else { return }
        store.create(text: item.text, source: .dictation) { [weak self] result in
            if case .failure = result { self?.savedDictations.remove(item.id) }
        }
    }
}
