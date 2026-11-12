import AppKit
import AVFoundation
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences.shared
    private let engine = EngineController()
    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyMonitor()
    private let overlay = Overlay()
    private var promptObserver: AnyCancellable?
    /// The calendar event a call was last noticed during.
    private var detectedCall: MeetingCalendar.Event?
    /// Meetings whose pill prompt was used or waved away.
    private var dismissedPrompts = Set<String>()
    private let editWatcher = EditWatcher()
    private lazy var indexer = PersonalIndexer(engine: engine)
    private let notes = NotesController.shared
    private lazy var meetings = MeetingController(engine: engine, overlay: overlay)

    private var statusItem: NSStatusItem!
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: NSWindow?
    private var prefsObserver: AnyCancellable?
    private var signalSources: [DispatchSourceSignal] = []

    private enum Phase { case idle, listening, processing }
    private var phase = Phase.idle { didSet { updateStatusIcon() } }

    /// Captured when recording starts, so the text goes where the user was.
    private var pendingContext: Context?
    /// The engine is transcribing the current recording as it goes.
    private var liveDictation = false
    private var lastInsert: (text: String, appId: String)?
    private var started = false
    private var heardSpeech = false
    private var silentSince: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let atLogin = Self.launchedAtLogin
        Log.info("FnSpeak \(AppInfo.version) starting on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\(atLogin ? ", at login" : "")")
        Log.info("Permissions: microphone \(Self.microphoneState), accessibility \(ContextReader.requestAccessibility(prompt: false) ? "allowed" : "off")")
        quitOnTerminationSignal()
        MainMenu.install(target: self, settings: #selector(openSettings), about: #selector(openAbout))
        if let folder = ProcessInfo.processInfo.environment["FNSPEAK_KIT_GALLERY"] {
            return KitGallery.render(into: URL(fileURLWithPath: folder, isDirectory: true))
        }
        if let directory = DevTools.snapshotDirectory {
            return DevTools.run(engine: engine, indexer: indexer, into: directory)
        }
        Preferences.shared.applyAppearance()
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
                    cancelMic: { [weak self] in
                        self?.hotkeys.recordingEnded()
                        self?.cancelRecording()
                    },
                    isListening: { [weak self] in self?.phase == .listening })
        meetings.onRecordingChange = { [weak self] in
            self?.updateStatusIcon()
            self?.updateMeetingPrompt()
        }
        meetings.isDictating = { [weak self] in self?.phase != .idle }
        meetings.onCallDetected = { [weak self] event in
            self?.detectedCall = event
            self?.updateMeetingPrompt()
        }
        promptObserver = UpcomingMeetings.shared.$meetings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMeetingPrompt() }
        // "in 9 min" counts down, and a meeting comes into range, between calendar changes.
        let promptTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.updateMeetingPrompt() }
        promptTimer.tolerance = 5
        RunLoop.main.add(promptTimer, forMode: .common)
        overlay.actions = [
            .init(id: "dictate", symbol: "mic.fill", label: "Dictate",
                  hint: "Start dictating. Press \(prefs.hotkey.displayName) to finish.") { [weak self] in self?.dictateFromPill() },
            .init(id: "note", symbol: "square.and.pencil", label: "Note",
                  hint: "Jot a note and start talking.") { [weak self] in self?.notes.newNote() },
            .init(id: "meeting", symbol: "record.circle", label: "Meeting",
                  hint: "Record and transcribe a meeting.") { [weak self] in self?.meetings.requestStart() },
            .init(id: "open", symbol: "macwindow", label: "Open",
                  hint: "Open FnSpeak.") { [weak self] in self?.showSettings(tab: .home) },
        ]
        setUpActions()
        AccountController.shared.engine = engine
        SettingsRouter.shared.openSettingsWindow = { [weak self] in self?.showSettingsWindow() }
        notes.showLibrary = { [weak self] in self?.showSettings(tab: .notesPage) }
        meetings.showLibrary = { [weak self] in self?.showSettings(tab: .meetingsPage) }
        UpcomingMeetings.shared.start()
        ModelDownloader.shared.onReady = { [weak self] item in self?.modelArrived(item) }

        if prefs.onboarded {
            begin()
            // Opened by hand, show the window; started at login, stay out of the way.
            // A missing permission means dictation can't work, so say so even then.
            if !atLogin || !Permission.missing.isEmpty { showSettings(tab: .home) }
        } else {
            showOnboarding()
        }
    }

    private static var microphoneState: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "allowed"
        case .notDetermined: return "not asked yet"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    /// `kill` and friends skip `applicationWillTerminate` unless asked nicely,
    /// which would leave the cleanup server running. Turn them into a quit.
    private func quitOnTerminationSignal() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Whether macOS started the app as a login item rather than the user opening it.
    private static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
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

    /// What fnspeak:// links and the Shortcuts actions can do. Each waits
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
            // The browser saying a sign-in is ready to collect. It carries
            // nothing, so it isn't one of the commands other apps can send.
            if url.scheme == "fnspeak", url.host == "signin" {
                AccountController.shared.finishGoogleSignIn()
                continue
            }
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
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                // Never asked, e.g. settings carried over from another Mac or
                // an older name: ask now rather than sending them to Settings.
                AudioRecorder.requestPermission { [weak self] granted in
                    self?.overlay.show(granted ? .message("Microphone allowed. Try again.") : .error("Microphone access is off"))
                }
            } else {
                overlay.show(.error("Microphone is off for FnSpeak in System Settings"))
                // The window says why it's needed and has the button to fix it.
                showSettings(tab: .home)
            }
            return false
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           let id = front.bundleIdentifier, prefs.excludedApps.contains(id) {
            overlay.show(.message("Dictation is off in \(front.localizedName ?? "this app")"))
            return false
        }
        let context = ContextReader.current()
        pendingContext = context
        // Transcribe while the user talks, so release has little left to do.
        let sink = engine.beginDictation(context: context)
        liveDictation = sink != nil
        do {
            try recorder.start(onChunk: sink)
            heardSpeech = false
            silentSince = nil
            Sounds.start()
            phase = .listening
            overlay.show(.listening(handsFree: prefs.triggerStyle == "toggle"))
            return true
        } catch {
            endLiveDictation()
            overlay.show(.error("Couldn't start the microphone"))
            return false
        }
    }

    /// A model finished downloading: start using it if it's what was missing.
    private func modelArrived(_ item: ModelDownloader.Item) {
        guard started else { return }
        switch item {
        case .whisper, .parakeet:
            if !engine.isReady { engine.load() }
        case .cleanup:
            if prefs.mode == "local" {
                if engine.isReady { engine.reconfigureCleanup() } else if engine.status != .loading { engine.load() }
            }
        case .speakers:
            break // The next meeting finds it on its own.
        }
    }

    /// Drop the live session, when a recording ends without being dictated.
    private func endLiveDictation() {
        if liveDictation { engine.cancelDictation() }
        liveDictation = false
    }

    private func finishRecording() {
        let audio = recorder.stop()
        Sounds.stop()
        phase = .idle
        guard let context = pendingContext else {
            endLiveDictation()
            return overlay.show(.hidden)
        }
        pendingContext = nil
        // Under ~0.3 s there's nothing to transcribe.
        guard audio.count > 4_800 else {
            endLiveDictation()
            return overlay.show(.hidden)
        }
        guard engine.isReady else {
            endLiveDictation()
            if case .failed(let message) = engine.status { return overlay.show(.error(Overlay.reason(message))) }
            return overlay.show(.message("Still loading the speech model"))
        }

        overlay.show(.working)
        phase = .processing
        let done: (Result<Dictation, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.phase = .idle
            switch result {
            case .success(let dictation):
                Log.info("Dictation ok: stt \(dictation.sttMs) ms after release (\(dictation.sttLiveMs) ms while talking), cleanup \(dictation.cleanupMs) ms (\(dictation.cleanerLabel))")
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
                // Snippet text isn't something the user dictated; edits to it teach nothing.
                if self.prefs.learnFromCorrections, dictation.expandedSnippets == 0 { self.editWatcher.watch(dictation.insert) }
                RecentDictations.shared.add(dictation.text)
                self.overlay.show(.pasted)
            case .failure(let error):
                Log.error("Dictation failed: \(error.localizedDescription)")
                self.overlay.show(.error(Overlay.reason(for: error)))
            }
        }
        if liveDictation {
            liveDictation = false
            engine.finishDictation(audio, context: context, completion: done)
        } else {
            engine.dictate(audio, context: context, completion: done)
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
        endLiveDictation()
        phase = .idle
        pendingContext = nil
        overlay.show(.hidden)
    }

    /// The pill's Dictate: a hands-free dictation into whatever app is in
    /// front, finished with the hotkey or by going quiet.
    private func dictateFromPill() {
        guard phase == .idle, startRecording() else { return }
        hotkeys.recordingStartedElsewhere()
        overlay.show(.listening(handsFree: true))
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
            (symbol, label) = ("mic.slash", "FnSpeak (paused)")
        } else {
            switch phase {
            case .idle: (symbol, label) = ("waveform", "FnSpeak")
            case .listening: (symbol, label) = ("mic.fill", "FnSpeak (listening)")
            case .processing: (symbol, label) = ("ellipsis.circle", "FnSpeak (working)")
            }
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        if meetings.isRecording { statusItem.button?.image = MeetingStatusBadge.badge(statusItem.button?.image) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings(tab: .home) }
        return true
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "FnSpeak")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        showSettings(tab: .general)
    }

    @objc private func openHome() {
        showSettings(tab: .home)
    }

    @objc private func openHistory() {
        showSettings(tab: .history)
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

    /// Show a page: settings pages open the settings window, the rest the
    /// main one. With no page, the main window as it was left.
    private func showSettings(tab: SettingsTab? = nil) {
        if let tab, SettingsTab.settings.contains(tab) {
            // The router opens the settings window through `openSettingsWindow`.
            SettingsRouter.shared.tab = tab
            return
        }
        if mainWindow == nil {
            let actions = MainWindowActions(
                newNote: { [weak self] in self?.notes.newNote() },
                startMeeting: { [weak self] in self?.meetings.requestStart() },
                meetings: meetings,
                togglePause: { [weak self] in self?.togglePause() }
            )
            mainWindow = MainWindowController(engine: engine, indexer: indexer, actions: actions)
        }
        mainWindow?.show(tab: tab)
    }

    private func showSettingsWindow() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(engine: engine, indexer: indexer)
        }
        settingsWindow?.show()
    }

    // MARK: - Meetings on the calendar

    /// What the pill offers: recording a call that was just noticed, or the
    /// meeting that's on or starts in the next ten minutes.
    private func updateMeetingPrompt() {
        guard meetings.phase == .idle else { return overlay.setMeetingPrompt(nil) }
        if let call = detectedCall, call.end > Date(), !dismissedPrompts.contains(call.id) {
            let prompt = Overlay.MeetingPrompt(id: call.id, title: call.title, when: "", action: "Record", detected: true)
            return overlay.setMeetingPrompt(prompt, action: { [weak self] in
                self?.dismissedPrompts.insert(call.id)
                self?.meetings.requestStart(title: call.title)
                self?.updateMeetingPrompt()
            }, dismiss: { [weak self] in
                self?.dismissedPrompts.insert(call.id)
                self?.updateMeetingPrompt()
            })
        }
        guard let next = UpcomingMeetings.shared.next, !dismissedPrompts.contains(next.id),
              next.isNow() || next.start.timeIntervalSinceNow <= 10 * 60 else { return overlay.setMeetingPrompt(nil) }
        let prompt = Overlay.MeetingPrompt(id: next.id, title: next.title, when: next.when(),
                                           action: next.joinURL == nil ? "Record" : "Join and Record", detected: false)
        overlay.setMeetingPrompt(prompt, action: { [weak self] in
            self?.dismissedPrompts.insert(next.id)
            if let url = next.joinURL { NSWorkspace.shared.open(url) }
            self?.meetings.requestStart(title: next.title)
            self?.updateMeetingPrompt()
        }, dismiss: { [weak self] in
            self?.dismissedPrompts.insert(next.id)
            self?.updateMeetingPrompt()
        })
    }

    @objc private func joinMeeting(_ sender: NSMenuItem) {
        guard let meeting = sender.representedObject as? MeetingBox, let url = meeting.value.joinURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func joinAndRecordMeeting(_ sender: NSMenuItem) {
        guard let meeting = sender.representedObject as? MeetingBox else { return }
        if let url = meeting.value.joinURL { NSWorkspace.shared.open(url) }
        meetings.requestStart(title: meeting.value.title)
    }

    /// The meeting that's on or about to start, at the top of the menu.
    private func addUpcomingMeeting(to menu: NSMenu) {
        guard let meeting = UpcomingMeetings.shared.next else { return }
        let box = MeetingBox(meeting)
        let title = meeting.title.count > 40 ? String(meeting.title.prefix(39)) + "…" : meeting.title
        let header = NSMenuItem(title: "\(title) · \(meeting.when())", action: nil, keyEquivalent: "")
        header.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
        menu.addItem(header)
        if meeting.joinURL != nil {
            let service = meeting.service.map { " on \($0)" } ?? ""
            let both = NSMenuItem(title: "Join\(service) and Record", action: #selector(joinAndRecordMeeting(_:)), keyEquivalent: "")
            both.target = self
            both.representedObject = box
            both.indentationLevel = 1
            both.isEnabled = !meetings.isRecording
            menu.addItem(both)
            let join = NSMenuItem(title: "Join\(service)", action: #selector(joinMeeting(_:)), keyEquivalent: "")
            join.target = self
            join.representedObject = box
            join.indentationLevel = 1
            menu.addItem(join)
        } else if !meetings.isRecording {
            let record = NSMenuItem(title: "Record This Meeting", action: #selector(joinAndRecordMeeting(_:)), keyEquivalent: "")
            record.target = self
            record.representedObject = box
            record.indentationLevel = 1
            menu.addItem(record)
        }
        menu.addItem(.separator())
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
                self?.showSettings(tab: .home)
            }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "FnSpeak"
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
        let open = NSMenuItem(title: "Open FnSpeak", action: #selector(openHome), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        addUpcomingMeeting(to: menu)
        if let missing = Permission.missing.first {
            let fix = NSMenuItem(title: "FnSpeak needs \(missing == .microphone ? "the microphone" : "Accessibility")…", action: #selector(openHome), keyEquivalent: "")
            fix.target = self
            fix.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(fix)
        }
        menu.addItem(withTitle: prefs.paused ? "Paused" : status, action: nil, keyEquivalent: "")
        if let warning = engine.cleanupWarning {
            menu.addItem(withTitle: warning, action: nil, keyEquivalent: "")
        }
        if let last = engine.lastDictation {
            let item = NSMenuItem(title: "Last: \(last.totalMs) ms (\(last.cleanerLabel))", action: nil, keyEquivalent: "")
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
            let all = NSMenuItem(title: "Show History…", action: #selector(openHistory), keyEquivalent: "")
            all.target = self
            submenu.addItem(all)
            let clear = NSMenuItem(title: "Clear This List", action: #selector(clearRecents), keyEquivalent: "")
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
        let quit = NSMenuItem(title: "Quit FnSpeak", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }
}

/// A meeting carried by a menu item, which can only hold objects.
private final class MeetingBox: NSObject {
    let value: UpcomingMeeting
    init(_ value: UpcomingMeeting) { self.value = value }
}
