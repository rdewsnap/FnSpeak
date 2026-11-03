import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences.shared
    private let engine = EngineController()
    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyMonitor()
    private let overlay = Overlay()
    private let editWatcher = EditWatcher()
    private lazy var indexer = PersonalIndexer(engine: engine)
    private let notes = NotesController.shared
    private lazy var meetings = MeetingController(engine: engine, overlay: overlay)

    private var statusItem: NSStatusItem!
    private var settingsController: SettingsWindowController?
    private var onboardingWindow: NSWindow?
    private var prefsObserver: AnyCancellable?

    private enum Phase { case idle, listening, processing }
    private var phase = Phase.idle { didSet { updateStatusIcon() } }

    /// Captured when recording starts, so the text goes where the user was.
    private var pendingContext: Context?
    private var lastInsert: (text: String, appId: String)?
    private var started = false
    private var heardSpeech = false
    private var silentSince: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Flowstate \(AppInfo.version) starting on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        MainMenu.install(target: self, settings: #selector(openSettings), about: #selector(openAbout))
        setUpStatusItem()
        applyPresentation()
        prefsObserver = prefs.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.applyPresentation() }
        // Any real window (settings, notes, a meeting) puts the app in the Dock
        // while it's open, so there's something to click on and ⌘Q to press.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowsChanged(_:)), name: name, object: nil)
        }
        recorder.onLevel = { [weak self] in self?.handleLevel($0) }
        hotkeys.onStart = { [weak self] in self?.startRecording() ?? false }
        hotkeys.onFinish = { [weak self] in self?.finishRecording() }
        hotkeys.onCancel = { [weak self] in self?.cancelRecording() }
        hotkeys.onHandsFree = { [weak self] in self?.overlay.show(.listening(handsFree: true)) }
        hotkeys.onSwapToRaw = { [weak self] in self?.swapToRaw() }
        editWatcher.onEdit = { [weak self] in self?.learn(inserted: $0, edited: $1) }
        notes.start(engine: engine, toggleMic: { [weak self] in self?.toggleNoteDictation() },
                    isListening: { [weak self] in self?.phase == .listening })
        meetings.onRecordingChange = { [weak self] in self?.updateStatusIcon() }
        overlay.onIdleClick = { [weak self] in self?.notes.newNote() }
        setUpActions()
        AccountController.shared.engine = engine

        if prefs.onboarded {
            begin()
        } else {
            showOnboarding()
        }
    }

    private func begin() {
        guard !started else { return }
        started = true
        engine.load()
        hotkeys.start()
        meetings.begin()
        MainActor.assumeIsolated { SyncEngine.shared.start(engine: engine, meetings: meetings) }
        // Contacts and Calendar prompts wait until onboarding is done.
        if prefs.onboarded { scheduleIndexing() }
    }

    private func scheduleIndexing() {
        // Index once the engine has its databases open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.indexer.indexAll() }
    }

    // MARK: - Links and Shortcuts

    /// What flowstate:// links and the Shortcuts actions can do. Each waits
    /// for the engine, since a link can be what launched the app.
    private func setUpActions() {
        let actions = AppActions.shared
        actions.toggleDictation = { [weak self] in self?.whenEngineReady { self?.toggleNoteDictation() } }
        actions.startMeeting = { [weak self] title in self?.whenEngineReady { self?.meetings.requestStart(title: title) } }
        actions.stopMeeting = { [weak self] in self?.meetings.stop() }
        actions.openMeeting = { [weak self] id in self?.whenEngineReady { self?.meetings.open(id: id) } }
        actions.isRecordingMeeting = { [weak self] in self?.meetings.isRecording ?? false }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            whenEngineReady { URLCommands.handle(url) }
        }
    }

    private var engineWaiters: [() -> Void] = []
    private var engineWatch: AnyCancellable?

    private func whenEngineReady(_ work: @escaping () -> Void) {
        guard !engine.isReady else { return work() }
        if case .failed = engine.status { return work() }
        engineWaiters.append(work)
        guard engineWatch == nil else { return }
        engineWatch = engine.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, status != .loading else { return }
                let waiting = self.engineWaiters
                self.engineWaiters = []
                self.engineWatch = nil
                waiting.forEach { $0() }
            }
    }

    // MARK: - Dictation

    private func startRecording() -> Bool {
        // Whatever the user did to the last dictation, they're done with it.
        editWatcher.finish()
        guard !prefs.paused else {
            overlay.show(.message("Dictation is paused"))
            return false
        }
        guard AudioRecorder.hasPermission else {
            overlay.show(.error("Microphone access is off"))
            return false
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           let id = front.bundleIdentifier, prefs.excludedApps.contains(id) {
            overlay.show(.message("Dictation is off in \(front.localizedName ?? "this app")"))
            return false
        }
        pendingContext = ContextReader.current()
        do {
            try recorder.start()
            heardSpeech = false
            silentSince = nil
            Sounds.start()
            phase = .listening
            overlay.show(.listening(handsFree: prefs.triggerStyle == "toggle"))
            return true
        } catch {
            overlay.show(.error("Couldn't start the microphone"))
            return false
        }
    }

    private func finishRecording() {
        let audio = recorder.stop()
        Sounds.stop()
        phase = .idle
        guard let context = pendingContext else { return overlay.show(.hidden) }
        pendingContext = nil
        // Under ~0.3 s there's nothing to transcribe.
        guard audio.count > 4_800 else { return overlay.show(.hidden) }
        guard engine.isReady else {
            if case .failed(let message) = engine.status { return overlay.show(.error(Overlay.reason(message))) }
            return overlay.show(.message("Still loading the speech model"))
        }

        overlay.show(.working)
        phase = .processing
        engine.dictate(audio, context: context) { [weak self] result in
            guard let self else { return }
            self.phase = .idle
            switch result {
            case .success(let dictation):
                Log.info("Dictation ok: stt \(dictation.sttMs) ms, cleanup \(dictation.cleanupMs) ms (\(dictation.cleaner ?? "no model"))")
                let send = dictation.pressEnter && self.prefs.allowSendCommand
                guard !dictation.insert.isEmpty else {
                    // "Send it" on its own sends what's already typed.
                    if send, !self.notes.bar.wantsDictation { TextInserter.pressReturn(after: 0) }
                    return self.overlay.show(.hidden)
                }
                if self.notes.insertDictation(dictation.insert) { return self.overlay.show(.pasted) }
                TextInserter.insert(dictation.insert, bundleId: context.appId)
                if send { TextInserter.pressReturn() }
                self.lastInsert = (dictation.insert, context.appId)
                if self.prefs.learnFromCorrections { self.editWatcher.watch(dictation.insert) }
                RecentDictations.shared.add(dictation.text)
                self.overlay.show(.pasted)
            case .failure(let error):
                Log.error("Dictation failed: \(error.localizedDescription)")
                self.overlay.show(.error(Overlay.reason(for: error)))
            }
        }
    }

    private func handleLevel(_ level: Float) {
        overlay.setLevel(level)
        guard phase == .listening, prefs.autoStopEnabled else { return }
        if level > 0.12 {
            heardSpeech = true
            silentSince = nil
            return
        }
        // Only a pause after speech counts, not the quiet before you start.
        guard heardSpeech else { return }
        let since = silentSince ?? Date()
        silentSince = since
        if Date().timeIntervalSince(since) >= prefs.autoStopSeconds {
            hotkeys.recordingEnded()
            finishRecording()
        }
    }

    private func cancelRecording() {
        recorder.stop()
        phase = .idle
        pendingContext = nil
        overlay.show(.hidden)
    }

    /// The notes bar's mic button: start a dictation, or finish the running one.
    private func toggleNoteDictation() {
        if phase == .listening {
            hotkeys.recordingEnded()
            finishRecording()
        } else {
            _ = startRecording()
        }
    }

    private func swapToRaw() {
        guard let last = lastInsert, let raw = engine.lastRaw(), !raw.isEmpty,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == last.appId else { return }
        TextInserter.replacePrevious(last.text.count, with: raw)
        lastInsert = (raw, last.appId)
        if prefs.learnFromCorrections { editWatcher.watch(raw) }
    }

    private func learn(inserted: String, edited: String) {
        guard prefs.learnFromCorrections else { return }
        engine.learnFromEdit(inserted: inserted, edited: edited) { [weak self] learned in
            guard let self, !learned.isEmpty, self.overlay.isIdle else { return }
            let names = learned.map(\.corrected).joined(separator: ", ")
            self.overlay.showLearned("Learned \(names)") { [weak self] in self?.engine.forget(learned) }
        }
    }

    // MARK: - UI

    /// Menu bar icon and Dock presence follow the prefs; at least one stays on.
    /// The Dock icon also appears whenever a window is open, whatever the pref.
    private func applyPresentation(closing: NSWindow? = nil) {
        statusItem.isVisible = prefs.showInMenuBar || !prefs.showInDock
        let hasWindow = NSApp.windows.contains { $0 !== closing && $0.isVisible && !($0 is NSPanel) }
        let policy: NSApplication.ActivationPolicy = prefs.showInDock || hasWindow ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        updateStatusIcon()
        // objectWillChange fires before the new value lands; look next turn.
        DispatchQueue.main.async { [weak self] in self?.overlay.refreshIdle() }
    }

    @objc private func windowsChanged(_ note: Notification) {
        let closing = note.name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
        applyPresentation(closing: closing)
    }

    private func updateStatusIcon() {
        let (symbol, label): (String, String)
        if prefs.paused {
            (symbol, label) = ("mic.slash", "Flowstate (paused)")
        } else {
            switch phase {
            case .idle: (symbol, label) = ("waveform", "Flowstate")
            case .listening: (symbol, label) = ("mic.fill", "Flowstate (listening)")
            case .processing: (symbol, label) = ("ellipsis.circle", "Flowstate (working)")
            }
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        if meetings.isRecording { statusItem.button?.image = MeetingStatusBadge.badge(statusItem.button?.image) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings() }
        return true
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Flowstate")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        showSettings()
    }

    @objc func showMeetings(_ sender: Any?) {
        meetings.showList()
    }

    @objc private func openAccount() {
        showSettings(tab: .account)
    }

    @objc private func openAbout() {
        showSettings(tab: .about)
    }

    private func showSettings(tab: SettingsTab? = nil) {
        if settingsController == nil {
            settingsController = SettingsWindowController(engine: engine, indexer: indexer)
        }
        settingsController?.show(tab: tab)
    }

    private func showOnboarding() {
        let view = OnboardingView(
            engine: engine,
            hardware: detectHardware(),
            prepare: { [weak self] in self?.prepareForTryIt(mode: $0) },
            onDone: { [weak self] in
                self?.onboardingWindow?.close()
                self?.begin()
                self?.scheduleIndexing()
            }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Flowstate"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// The try-it step needs a running engine and hotkey before onboarding is done.
    private func prepareForTryIt(mode: String) {
        let changed = prefs.mode != mode
        prefs.mode = mode
        if started {
            if changed { engine.reconfigureCleanup() }
        } else {
            begin()
        }
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        prefs.mode = mode
        engine.reconfigureCleanup()
    }

    @objc private func togglePause() {
        prefs.paused.toggle()
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func clearRecents() {
        RecentDictations.shared.clear()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// The Dock icon's menu is the same as the menu bar's.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuilt on open so it always reflects the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let key = prefs.hotkey.displayName
        let status: String
        switch engine.status {
        case .loading: status = "Loading speech model…"
        case .ready: status = prefs.triggerStyle == "toggle" ? "Ready — press \(key) to dictate" : "Ready — hold \(key) to dictate"
        case .failed(let message): status = "Problem: \(message)"
        }
        menu.addItem(withTitle: prefs.paused ? "Paused" : status, action: nil, keyEquivalent: "")
        if let warning = engine.cleanupWarning {
            menu.addItem(withTitle: warning, action: nil, keyEquivalent: "")
        }
        if let last = engine.lastDictation {
            let item = NSMenuItem(title: "Last: \(last.totalMs) ms (\(last.cleaner ?? "no model"))", action: nil, keyEquivalent: "")
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let modes: [(String, String)] = [("local", "Local cleanup"), ("cloud", "Cloud cleanup"), ("filterOnly", "Filter only"), ("raw", "Raw")]
        for (value, title) in modes {
            let item = NSMenuItem(title: title, action: #selector(setMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = prefs.mode == value ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let pause = NSMenuItem(title: "Pause dictation", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = prefs.paused ? .on : .off
        menu.addItem(pause)

        let recents = NSMenuItem(title: "Recent dictations", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let items = RecentDictations.shared.items
        if items.isEmpty {
            submenu.addItem(withTitle: "Nothing yet", action: nil, keyEquivalent: "")
        } else {
            for entry in items {
                let oneLine = entry.text.replacingOccurrences(of: "\n", with: " ")
                let title = oneLine.count > 48 ? String(oneLine.prefix(47)) + "…" : oneLine
                let item = NSMenuItem(title: title, action: #selector(copyRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                item.toolTip = "Click to copy"
                submenu.addItem(item)
            }
            submenu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear", action: #selector(clearRecents), keyEquivalent: "")
            clear.target = self
            submenu.addItem(clear)
        }
        recents.submenu = submenu
        menu.addItem(recents)
        menu.addItem(.separator())
        notes.addMenuItems(to: menu)
        meetings.addMenuItems(to: menu)
        menu.addItem(.separator())

        let account = NSMenuItem(title: "Account…", action: #selector(openAccount), keyEquivalent: "")
        account.target = self
        menu.addItem(account)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Flowstate", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }
}
