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
enum DevTools {
    static var snapshotDirectory: URL? {
        ProcessInfo.processInfo.environment["FNSPEAK_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(engine: EngineController, indexer: PersonalIndexer, into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.regular)
        engine.load()
        waitForEngine(engine) {
            selfTest(engine: engine, directory: directory) {
                let controller = MainWindowController(engine: engine, indexer: indexer, actions: MainWindowActions())
                controller.window?.setContentSize(NSSize(width: 940, height: 680))
                controller.show(tab: .home)
                var shots: [(SettingsTab, NSAppearance.Name)] = []
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    for tab in SettingsTab.allCases { shots.append((tab, appearance)) }
                }
                capture(shots[...], controller: controller, directory: directory) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func waitForEngine(_ engine: EngineController, then work: @escaping () -> Void) {
        if engine.status != .loading { return work() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitForEngine(engine, then: work) }
    }

    private static func capture(_ shots: ArraySlice<(SettingsTab, NSAppearance.Name)>, controller: MainWindowController,
                                directory: URL, done: @escaping () -> Void) {
        guard let (tab, appearance) = shots.first, let window = controller.window, let view = window.contentView else { return done() }
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
            capture(shots.dropFirst(), controller: controller, directory: directory, done: done)
        }
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
                finish("ok in \(ms) ms (stt \(d.sttMs) ms, cleanup \(d.cleanupMs) ms, \(d.cleaner ?? "no model"))\nraw: \(d.raw)\ntext: \(d.text)\nwarning: \(engine.cleanupWarning ?? "none")\n")
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
