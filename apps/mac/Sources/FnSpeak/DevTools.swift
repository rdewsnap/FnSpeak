import AppKit
import SwiftUI

/// Developer hooks, switched on by environment variables and never by anything
/// in the UI. They let the build be checked without a person at the keyboard.
///
///   FNSPEAK_SNAPSHOTS=/some/dir   draw every page of the main window to PNGs
///                                 there (light and dark), then quit
///   FNSPEAK_SELFTEST=clip.wav     with the above: also run that 16 kHz mono
///                                 WAV through the loaded engine and write the
///                                 result to selftest.txt
///   FNSPEAK_DOWNLOAD=whisper      with the above: download that model first,
///                                 the way the Download button would
///   FNSPEAK_PREVIEW_PERMISSIONS=off   draw everything as if the microphone
///                                 and Accessibility were switched off
///   FNSPEAK_PREVIEW_MEETING=1     draw the app with a meeting about to start
///   FNSPEAK_PREVIEW_PLAN=1        draw the account page signed in, on a made-up plan
///   FNSPEAK_PREVIEW_SIGNIN=1      draw the account page signed out, with Google on offer
///   FNSPEAK_PREVIEW_CALENDARS=1   draw Connectors with a made-up Google account
///                                 ("refused": as if calendars were switched off)
///   FNSPEAK_KIT_GALLERY=/some/dir draw the design kit's gallery sheets there
///                                 (light and dark) and quit, without loading anything
///   FNSPEAK_DATA_DIR=/some/dir    use this instead of Application Support
///                                 (see ModelLocator), to leave real data alone
enum DevTools {
    static var snapshotDirectory: URL? {
        ProcessInfo.processInfo.environment["FNSPEAK_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(engine: EngineController, indexer: PersonalIndexer, into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.regular)
        download(into: directory) {
          let loadStarted = Date()
          engine.load()
          waitForEngine(engine) {
            let loadMs = Int(Date().timeIntervalSince(loadStarted) * 1000)
            try? "engine \(engine.status) after \(loadMs) ms\n".write(to: directory.appendingPathComponent("load.txt"), atomically: true, encoding: .utf8)
            selfTest(engine: engine, directory: directory) {
                let controller = MainWindowController(engine: engine, indexer: indexer, actions: MainWindowActions())
                controller.window?.setContentSize(NSSize(width: 1000, height: 700))
                controller.show(tab: .home)
                let settings = SettingsWindowController(engine: engine, indexer: indexer)
                settings.show()
                var shots: [(SettingsTab, NSAppearance.Name)] = []
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    for tab in SettingsTab.allCases { shots.append((tab, appearance)) }
                }
                capture(shots[...], windows: (controller, settings), directory: directory) {
                    onboarding(engine: engine, directory: directory) { NSApp.terminate(nil) }
                }
            }
          }
        }
    }

    private static func waitForEngine(_ engine: EngineController, then work: @escaping () -> Void) {
        if engine.status != .loading { return work() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitForEngine(engine, then: work) }
    }

    private static func capture(_ shots: ArraySlice<(SettingsTab, NSAppearance.Name)>,
                                windows: (main: MainWindowController, settings: SettingsWindowController),
                                directory: URL, done: @escaping () -> Void) {
        guard let (tab, appearance) = shots.first else { return done() }
        let inSettings = SettingsTab.settings.contains(tab)
        // The frame around the content, so the title bar and its buttons are in the picture.
        guard let window = inSettings ? windows.settings.window : windows.main.window,
              let view = window.contentView?.superview ?? window.contentView else { return done() }
        window.appearance = NSAppearance(named: appearance)
        SettingsRouter.shared.tab = tab
        // Give SwiftUI a moment to lay the page out and load its data.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let suffix = appearance == .darkAqua ? "-dark" : ""
                let file = directory.appendingPathComponent("\(tab.rawValue)\(suffix).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
            }
            capture(shots.dropFirst(), windows: windows, directory: directory, done: done)
        }
    }

    /// Download the model named in FNSPEAK_DOWNLOAD, if any, then carry on.
    private static func download(into directory: URL, then work: @escaping () -> Void) {
        guard let name = ProcessInfo.processInfo.environment["FNSPEAK_DOWNLOAD"],
              let item = ModelDownloader.Item(rawValue: name) else { return work() }
        let started = Date()
        ModelDownloader.shared.download(item)
        func poll() {
            let state = ModelDownloader.shared.state(item)
            let waiting: Bool
            switch state {
            case .downloading, .unpacking: waiting = true
            case .idle, .failed: waiting = false
            }
            if waiting { return DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll) }
            let seconds = Int(Date().timeIntervalSince(started))
            try? "\(name): \(state), present \(item.isPresent), \(seconds) s\n"
                .write(to: directory.appendingPathComponent("download.txt"), atomically: true, encoding: .utf8)
            work()
        }
        poll()
    }

    /// Each onboarding step, in its own window.
    private static func onboarding(engine: EngineController, directory: URL, done: @escaping () -> Void) {
        func shoot(_ step: Int) {
            guard step < 5 else { return done() }
            let view = OnboardingView(engine: engine, hardware: detectHardware(), prepare: { _ in }, onDone: {}, startAt: step)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.backgroundColor = Theme.pageNSColor
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: directory.appendingPathComponent("onboarding-\(step).png"))
                }
                window.close()
                shoot(step + 1)
            }
        }
        shoot(0)
    }

    private static func selfTest(engine: EngineController, directory: URL, done: @escaping () -> Void) {
        guard let path = ProcessInfo.processInfo.environment["FNSPEAK_SELFTEST"], !path.isEmpty else { return done() }
        let out = directory.appendingPathComponent("selftest.txt")
        func finish(_ text: String) {
            try? text.write(to: out, atomically: true, encoding: .utf8)
            done()
        }
        guard engine.isReady else { return finish("engine: \(engine.status)\n") }
        guard let samples = wavSamples(URL(fileURLWithPath: path)) else { return finish("could not read \(path)\n") }
        let context = Context(appId: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled", url: nil, textBefore: "", style: nil)
        let started = Date()
        engine.dictate(samples, context: context) { result in
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch result {
            case .success(let d):
                // Leave no trace of the test in the user's history.
                engine.history(limit: 1) { entries in
                    if let last = entries.first, last.text == d.text, last.appId == context.appId { engine.deleteHistoryEntry(last.id) }
                }
                finish("ok in \(ms) ms (stt \(d.sttMs) ms, cleanup \(d.cleanupMs) ms, \(d.cleanerLabel))\nraw: \(d.raw)\ntext: \(d.text)\nwarning: \(engine.cleanupWarning ?? "none")\n")
            case .failure(let error):
                finish("failed in \(ms) ms: \(error.localizedDescription)\n")
            }
        }
    }

    /// The samples of a 16-bit PCM WAV, as the engine wants them.
    private static func wavSamples(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        let bytes = [UInt8](data)
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<offset + 4], encoding: .ascii)
            let size = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8 | Int(bytes[offset + 6]) << 16 | Int(bytes[offset + 7]) << 24
            if id == "data" {
                let end = min(offset + 8 + size, bytes.count)
                return stride(from: offset + 8, to: end - 1, by: 2).map { i in
                    Float(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) / 32768
                }
            }
            offset += 8 + size + (size & 1)
        }
        return nil
    }
}
