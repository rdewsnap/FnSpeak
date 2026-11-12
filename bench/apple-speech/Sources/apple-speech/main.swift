// apple-speech: run the bench clips through Apple's built-in speech
// recognition and write a manifest fnspeak-bench can score.
//
// Each audio clip in the input manifest comes out as a transcript-only clip
// holding what Apple heard, so the bench scores it raw and through every
// cleanup mode, exactly as it does for Whisper.
//
//   --engine legacy    SFSpeechRecognizer, on-device (macOS 14+)
//   --engine dictation SpeechAnalyzer + DictationTranscriber (macOS 26+)
//   --engine speech    SpeechAnalyzer + SpeechTranscriber (macOS 26+)

import AVFoundation
import Foundation
import Speech

struct Options {
    var manifest = "bench/manifest.tts.jsonl"
    var vocab: String?
    var out = "bench/apple-speech/out/manifest.apple.jsonl"
    var engine = "legacy"
    var locale = "en-US"
    var hints = true
    var allowNetwork = false
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func value(_ flag: String) -> String {
        guard !args.isEmpty else { fail("\(flag) needs a value") }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let flag = args.removeFirst()
        switch flag {
        case "--manifest": o.manifest = value(flag)
        case "--vocab": o.vocab = value(flag)
        case "--out": o.out = value(flag)
        case "--engine": o.engine = value(flag)
        case "--locale": o.locale = value(flag)
        case "--no-hints": o.hints = false
        case "--allow-network": o.allowNetwork = true
        default: fail("unknown argument \(flag)")
        }
    }
    return o
}

/// Manifest lines as loose JSON, so fields this tool doesn't know pass through.
func loadManifest(_ path: String) -> [[String: Any]] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("can't read \(path)") }
    return text.split(separator: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("//") { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            fail("bad manifest line: \(trimmed)")
        }
        return object
    }
}

func loadVocab(_ path: String?) -> [String] {
    guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// Resumes a continuation once, however many times the callback fires.
final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

// MARK: - SFSpeechRecognizer (macOS 14+)

func authorize() async {
    let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
        SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
    }
    guard status == .authorized else {
        fail("Speech recognition isn't allowed for this tool (status \(status.rawValue)). Allow it in System Settings → Privacy & Security → Speech Recognition and run again.")
    }
}

func legacyTranscribe(_ url: URL, recognizer: SFSpeechRecognizer, hints: [String], onDevice: Bool) async -> Result<String, Error> {
    await withCheckedContinuation { (c: CheckedContinuation<Result<String, Error>, Never>) in
        let once = Once(c)
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = onDevice
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.contextualStrings = hints
        recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                once.resume(.success(result.bestTranscription.formattedString))
            } else if let error {
                once.resume(.failure(error))
            }
        }
    }
}

// MARK: - SpeechAnalyzer (macOS 26+)
// Written from Apple's documentation on a Mac that can't compile it yet
// (needs the macOS 26 SDK). Expect to fix small things on first build.

#if compiler(>=6.2)
@available(macOS 26.0, *)
func analyzerTranscribe(_ url: URL, engine: String, locale: Locale, hints: [String]) async throws -> String {
    let file = try AVAudioFile(forReading: url)
    let context = AnalysisContext()
    if !hints.isEmpty { context.contextualStrings[.general] = Array(hints.prefix(100)) }

    if engine == "dictation" {
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        async let text = transcriber.results.reduce(into: "") { text, result in
            if result.isFinal { text += String(result.text.characters) }
        }
        _ = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], analysisContext: context, finishAfterFile: true)
        return try await text
    } else {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        async let text = transcriber.results.reduce(into: "") { text, result in
            if result.isFinal { text += String(result.text.characters) }
        }
        _ = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], analysisContext: context, finishAfterFile: true)
        return try await text
    }
}
#endif

// MARK: - Run

let options = parseOptions()
let clips = loadManifest(options.manifest)
let base = URL(fileURLWithPath: options.manifest).deletingLastPathComponent()
let hints = options.hints ? loadVocab(options.vocab) : []
let locale = Locale(identifier: options.locale)

var recognizer: SFSpeechRecognizer?
if options.engine == "legacy" {
    await authorize()
    guard let r = SFSpeechRecognizer(locale: locale) else { fail("no recognizer for \(options.locale)") }
    r.queue = OperationQueue()
    guard r.isAvailable else { fail("the recognizer for \(options.locale) isn't available right now") }
    if !options.allowNetwork && !r.supportsOnDeviceRecognition {
        fail("on-device recognition isn't available for \(options.locale) on this Mac. Turn on Dictation in System Settings → Keyboard so the model downloads, or pass --allow-network.")
    }
    recognizer = r
}

var outLines: [String] = []
var totalMs = 0.0
var done = 0
for var clip in clips {
    guard let audio = clip["audio"] as? String, let id = clip["id"] as? String else { continue }
    let url = base.appendingPathComponent(audio)
    let started = Date()
    var text = ""
    switch options.engine {
    case "legacy":
        switch await legacyTranscribe(url, recognizer: recognizer!, hints: hints, onDevice: !options.allowNetwork) {
        case .success(let t): text = t
        case .failure(let error): note("\(id): failed, \(error.localizedDescription)")
        }
    case "dictation", "speech":
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            do { text = try await analyzerTranscribe(url, engine: options.engine, locale: locale, hints: hints) }
            catch { note("\(id): failed, \(error.localizedDescription)") }
        } else {
            fail("--engine \(options.engine) needs macOS 26")
        }
        #else
        fail("--engine \(options.engine) needs the macOS 26 SDK (Xcode 26) to build")
        #endif
    default:
        fail("unknown engine \(options.engine)")
    }
    let ms = Date().timeIntervalSince(started) * 1000
    totalMs += ms
    done += 1
    note(String(format: "%@  %4.0f ms  %@", id, ms, text))

    clip.removeValue(forKey: "audio")
    clip["transcript"] = text
    clip["apple_stt_ms"] = Int(ms.rounded())
    let data = try JSONSerialization.data(withJSONObject: clip, options: [.sortedKeys, .withoutEscapingSlashes])
    outLines.append(String(decoding: data, as: UTF8.self))
}

guard done > 0 else { fail("no audio clips in \(options.manifest)") }
let outURL = URL(fileURLWithPath: options.out)
try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try (outLines.joined(separator: "\n") + "\n").write(to: outURL, atomically: true, encoding: .utf8)
note(String(format: "%d clips, average %.0f ms, engine %@, %d hints, written to %@", done, totalMs / Double(done), options.engine, hints.count, options.out))
