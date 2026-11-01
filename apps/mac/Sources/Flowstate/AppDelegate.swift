import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences.shared
    private let engine = EngineController()
    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyMonitor()
    private let overlay = Overlay()
    private lazy var indexer = PersonalIndexer(engine: engine)

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    /// Captured when recording starts, so the text goes where the user was.
    private var pendingContext: Context?
    private var lastInsert: (text: String, appId: String)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        recorder.onLevel = { [weak self] in self?.overlay.setLevel($0) }
        hotkeys.onStart = { [weak self] in self?.startRecording() }
        hotkeys.onFinish = { [weak self] in self?.finishRecording() }
        hotkeys.onCancel = { [weak self] in self?.cancelRecording() }
        hotkeys.onSwapToRaw = { [weak self] in self?.swapToRaw() }

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

    private func startRecording() {
        guard AudioRecorder.hasPermission else {
            overlay.show(.message("Flowstate needs microphone access"))
            return
        }
        pendingContext = ContextReader.current()
        do {
            try recorder.start()
            overlay.show(.listening(handsFree: false))
        } catch {
            overlay.show(.message("Couldn't start the microphone"))
        }
    }

    private func finishRecording() {
        let audio = recorder.stop()
        guard let context = pendingContext else { return overlay.show(.hidden) }
        pendingContext = nil
        // Under ~0.3 s there's nothing to transcribe.
        guard audio.count > 4_800 else { return overlay.show(.hidden) }
        guard engine.isReady else {
            return overlay.show(.message(engine.status == .loading ? "Still loading the speech model" : "Speech model unavailable — see Settings"))
        }

        overlay.show(.working)
        engine.dictate(audio, context: context) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let dictation):
                self.overlay.show(.hidden)
                guard !dictation.insert.isEmpty else { return }
                TextInserter.insert(dictation.insert, bundleId: context.appId)
                self.lastInsert = (dictation.insert, context.appId)
            case .failure(let error):
                self.overlay.show(.message("Dictation failed: \(error.localizedDescription)"))
            }
        }
    }

    private func cancelRecording() {
        recorder.stop()
        pendingContext = nil
        overlay.show(.hidden)
    }

    private func swapToRaw() {
        guard let last = lastInsert, let raw = engine.lastRaw(), !raw.isEmpty,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == last.appId else { return }
        TextInserter.replacePrevious(last.text.count, with: raw)
        lastInsert = (raw, last.appId)
    }

    // MARK: - UI

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Flowstate")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(engine: engine, indexer: indexer)))
            window.title = "Flowstate Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuilt on open so it always reflects the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        switch engine.status {
        case .loading: status = "Loading speech model…"
        case .ready: status = "Ready — hold Fn to dictate"
        case .failed(let message): status = "Problem: \(message)"
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
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
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Flowstate", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }
}
