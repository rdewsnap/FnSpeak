import AppKit
import ApplicationServices

/// After a dictation is inserted, keeps an eye on the field it went into. If
/// the user fixes a word, the inserted text and the edited version of that
/// region go to `onEdit` so the engine can learn the spelling.
///
/// Only the dictated region is compared, nothing is stored or logged, and
/// each dictation is reported at most once.
final class EditWatcher {
    var onEdit: ((_ inserted: String, _ edited: String) -> Void)?

    /// First look after the user has had a moment to fix things.
    private let firstCheck: TimeInterval = 8
    private let checkEvery: TimeInterval = 4
    private let giveUpAfter: TimeInterval = 120
    /// Edits reaching further than this outside the dictation are other work.
    private let maxSpill = 200

    private struct Watch {
        let element: AXUIElement
        /// The field right after insertion, and where the dictation sits in it.
        let original: [UInt16]
        let start: Int
        let end: Int
        let insertedAt: Date
        var lastCheck: Date
        var lastRegion: [UInt16]?
        var away = false
    }

    private var watch: Watch?
    private var timer: Timer?
    private var activation: NSObjectProtocol?

    init() {
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.check(final: false, force: true) }
    }

    deinit {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
    }

    /// Start watching `text`, which was just inserted into the focused field.
    func watch(_ text: String) {
        stop()
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        // Pasting lands asynchronously; look once the app has caught up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.snapshot(needle)
        }
    }

    /// The user moved on (e.g. started another dictation): look one last time.
    func finish() {
        check(final: true, force: true)
    }

    private func snapshot(_ needle: String) {
        guard let element = ContextReader.focusedTextElement(), let value = ContextReader.value(of: element) else { return }
        let field = value as NSString
        guard field.length < 200_000 else { return }
        // The occurrence ending nearest the caret is the one just inserted.
        let caret = min(ContextReader.caret(in: element) ?? field.length, field.length)
        let found = field.range(of: needle, options: .backwards, range: NSRange(location: 0, length: caret))
        guard found.location != NSNotFound else { return }

        let now = Date()
        watch = Watch(
            element: element,
            original: Array(value.utf16),
            start: found.location,
            end: found.location + found.length,
            insertedAt: now,
            lastCheck: now,
            lastRegion: nil
        )
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard let w = watch else { return stop() }
        let age = Date().timeIntervalSince(w.insertedAt)
        if age >= giveUpAfter { return check(final: true, force: true) }
        let focused = ContextReader.focusedTextElement()
        let away = focused.map { !CFEqual($0, w.element) } ?? true
        if away != w.away {
            watch?.away = away
            // Leaving the field is the natural end of a fix-up.
            if away { check(final: false, force: true) }
            return
        }
        if !away && age >= firstCheck && Date().timeIntervalSince(w.lastCheck) >= checkEvery {
            check(final: false, force: false)
        }
    }

    /// Compare the field with what was inserted. Without `force`, only report
    /// an edit once it has held still between two looks, so a half-typed fix
    /// isn't mistaken for the finished one.
    private func check(final: Bool, force: Bool) {
        guard var w = watch else { return }
        defer { if final { stop() } }
        guard let value = ContextReader.value(of: w.element) else { return stop() }
        w.lastCheck = Date()

        let now = Array(value.utf16)
        guard let (inserted, edited) = region(of: w, in: now) else {
            watch = w
            return
        }
        if inserted == edited {
            watch = w
            return
        }
        if !force && edited != w.lastRegion {
            w.lastRegion = edited
            watch = w
            return
        }
        stop()
        let a = String(decoding: inserted, as: UTF16.self)
        let b = String(decoding: edited, as: UTF16.self)
        onEdit?(a, b)
    }

    /// The dictated region before and after editing: whatever lies between the
    /// unchanged text in front of it and the unchanged text behind it.
    private func region(of w: Watch, in now: [UInt16]) -> ([UInt16], [UInt16])? {
        let old = w.original
        var prefix = 0
        while prefix < min(old.count, now.count, w.start), old[prefix] == now[prefix] { prefix += 1 }
        var suffix = 0
        let tail = old.count - w.end
        while suffix < min(tail, now.count - prefix), old[old.count - 1 - suffix] == now[now.count - 1 - suffix] { suffix += 1 }
        guard w.start - prefix <= maxSpill, tail - suffix <= maxSpill else { return nil }

        let inserted = Array(old[prefix..<(old.count - suffix)])
        var edited = Array(now[prefix..<(now.count - suffix)])
        // Anything typed after the dictation is new writing, not a fix.
        let cap = inserted.count * 2 + maxSpill
        if edited.count > cap { edited = Array(edited[..<cap]) }
        return (inserted, edited)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        watch = nil
    }
}
