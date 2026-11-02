import AppKit
import Combine

/// Wires notes into the app: the global shortcut, the notes bar, and the
/// menu items. The app delegate owns dictation and hands this the hooks it
/// needs.
final class NotesController: NSObject {
    static let shared = NotesController()

    let bar = NotesBar()
    private let hotkey = NotesHotkey()
    private let prefs = Preferences.shared
    private let store = NotesStore.shared
    private var prefsObserver: AnyCancellable?

    /// Call once at launch.
    func start(engine: EngineController, toggleMic: @escaping () -> Void, isListening: @escaping () -> Bool) {
        store.engine = engine
        bar.toggleMic = toggleMic
        bar.isListening = isListening
        hotkey.onPress = { [weak self] in self?.bar.toggle() }
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
        menu.addItem(.separator())
    }

    @objc func newNote() {
        bar.show()
    }
}
