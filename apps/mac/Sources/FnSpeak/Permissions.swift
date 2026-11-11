import AVFoundation
import AppKit
import SwiftUI

/// The two things macOS has to allow before FnSpeak can dictate, with the
/// reason for each in words a person would accept.
enum Permission: String, CaseIterable, Identifiable {
    case microphone, accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: return "mic.fill"
        case .accessibility: return "keyboard"
        }
    }

    /// Why FnSpeak asks, and what it does with it.
    var why: String {
        switch self {
        case .microphone:
            return "So FnSpeak can hear you while you hold the key. Audio is turned into text on this Mac and never saved or sent anywhere."
        case .accessibility:
            return "So FnSpeak can notice the hotkey in any app, type the text where your cursor is, and see which field you're in to match its tone. It never reads password fields."
        }
    }

    enum State { case allowed, notAsked, off }

    var state: State {
        // For development: draw the app as it looks before anything is allowed.
        switch ProcessInfo.processInfo.environment["FNSPEAK_PREVIEW_PERMISSIONS"] {
        case "off": return .off
        case "notAsked": return .notAsked
        default: break
        }
        switch self {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .allowed
            case .notDetermined: return .notAsked
            default: return .off
            }
        case .accessibility:
            // macOS doesn't say whether it has asked before; its own prompt
            // sends people to the same place either way.
            return ContextReader.requestAccessibility(prompt: false) ? .allowed : .notAsked
        }
    }

    /// What the button says for the current state.
    var actionTitle: String {
        switch (self, state) {
        case (_, .allowed): return "Allowed"
        case (.microphone, .notAsked): return "Allow Microphone"
        case (.microphone, .off): return "Open Microphone Settings"
        case (.accessibility, _): return "Open Accessibility Settings"
        }
    }

    /// One line on what to do once System Settings is open.
    var settingsHint: String {
        switch self {
        case .microphone: return "In System Settings, turn on FnSpeak under Privacy & Security → Microphone."
        case .accessibility: return "In System Settings, turn on FnSpeak under Privacy & Security → Accessibility."
        }
    }

    /// Ask macOS, or open the right pane of System Settings when asking
    /// isn't possible any more. `done` runs when there may be a new answer.
    func request(done: @escaping () -> Void = {}) {
        switch (self, state) {
        case (_, .allowed):
            done()
        case (.microphone, .notAsked):
            AudioRecorder.requestPermission { _ in done() }
        case (.microphone, .off):
            Self.openSettings("Privacy_Microphone")
            done()
        case (.accessibility, _):
            // The system prompt only appears the first time; open the pane
            // as well so the button always does something visible.
            _ = ContextReader.requestAccessibility(prompt: true)
            Self.openSettings("Privacy_Accessibility")
            done()
        }
    }

    static var missing: [Permission] { allCases.filter { $0.state != .allowed } }

    private static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A permission with its reason, its state, and the button that fixes it.
/// Keeps itself up to date, since the answer changes in System Settings.
struct PermissionRow: View {
    let permission: Permission
    @State private var state: Permission.State
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    init(_ permission: Permission) {
        self.permission = permission
        _state = State(initialValue: permission.state)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state == .allowed ? "checkmark.circle.fill" : permission.symbol)
                .foregroundStyle(state == .allowed ? Color.green : Color.orange)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title).fontWeight(.medium)
                Text(permission.why).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state == .off || (permission == .accessibility && state != .allowed) {
                    Text(permission.settingsHint).font(.callout).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if state == .allowed {
                Text("Allowed").font(.callout).foregroundStyle(.secondary)
            } else {
                Button(permission.actionTitle) { permission.request { state = permission.state } }
            }
        }
        .onReceive(poll) { _ in state = permission.state }
    }
}
