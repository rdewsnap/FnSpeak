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

    private var statusItem: NSStatusItem!
    private var settingsController: SettingsWindowController?
    private var onboardingWindow: NSWindow?
    private var prefsObserver: AnyCancellable?

    private enum Phase { case idle, listening, processing }
    private var phase = Phase.idle { didSet { updateStatusIcon() } }

    /// Captured when recording starts, so the text goes where the user was.
    private var pendingContext: Context?
    private var lastInsert: (text: String, appId: String)?
    private var heardSpeech = false
    private var silentSince: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install(target: self, settings: #selector(openSettings), about: #selector(openAbout))
        setUpStatusItem()
        applyPresentation()
        prefsObserver = prefs.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.applyPresentation() }
        recorder.onLevel = { [weak self] in self?.handleLevel($0) }
        hotkeys.onStart = { [weak self] in self?.startRecording() ?? false }
        hotkeys.onFinish = { [weak self] in self?.finishRecording() }
        hotkeys.onCancel = { [weak self] in self?.cancelRecording() }
        hotkeys.onHandsFree = { [weak self] in self?.overlay.show(.listening(handsFree: true)) }
        hotkeys.onSwapToRaw = { [weak self] in self?.swapToRaw() }
        editWatcher.onEdit = { [weak self] in self?.learn(inserted: $0, edited: $1) }

        if prefs.onboarded {
            begin()
        } else {
            showOnboarding()
        }
    }

    private func begin() {
        engine.load()
        hotkeys.start()
        // Index once the engine has its databases open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.indexer.indexAll() }
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
                guard !dictation.insert.isEmpty else { return self.overlay.show(.hidden) }
                TextInserter.insert(dictation.insert, bundleId: context.appId)
                self.lastInsert = (dictation.insert, context.appId)
                if self.prefs.learnFromCorrections { self.editWatcher.watch(dictation.insert) }
                RecentDictations.shared.add(dictation.text)
                self.overlay.show(.pasted)
            case .failure(let error):
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
    private func applyPresentation() {
        statusItem.isVisible = prefs.showInMenuBar || !prefs.showInDock
        let policy: NSApplication.ActivationPolicy = prefs.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        updateStatusIcon()
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
        let view = OnboardingView(hardware: detectHardware()) { [weak self] in
            self?.onboardingWindow?.close()
            self?.begin()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Flowstate"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
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

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Flowstate", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }
}
