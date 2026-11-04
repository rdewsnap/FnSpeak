import AppKit
import Combine
import SwiftUI

/// The meeting window: setup, live transcript, then the summary.
final class MeetingWindowController: NSWindowController {
    private var subscription: AnyCancellable?

    init(controller: MeetingController) {
        let host = NSHostingController(rootView: MeetingWindowView(controller: controller))
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.title = "Meeting"
        window.setContentSize(NSSize(width: 580, height: 680))
        if !window.setFrameUsingName("FnSpeakMeeting") { window.center() }
        window.setFrameAutosaveName("FnSpeakMeeting")
        super.init(window: window)

        subscription = controller.$phase.combineLatest(controller.$draft, controller.$finished)
            .receive(on: DispatchQueue.main)
            .sink { [weak window] phase, draft, finished in
                switch phase {
                case .setup: window?.title = "New meeting"
                case .starting, .recording, .processing: window?.title = draft.title.isEmpty ? "Meeting" : draft.title
                case .idle: window?.title = finished?.title ?? "Meeting"
                }
            }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MeetingWindowView: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(spacing: 0) {
            if let error = controller.error {
                MeetingBanner(text: error, onDismiss: { controller.error = nil })
                    .padding([.horizontal, .top], 16)
            }
            switch controller.phase {
            case .setup:
                MeetingSetupView(controller: controller)
            case .starting:
                MeetingWaitingView(text: "Starting…")
            case .recording:
                MeetingLiveView(controller: controller)
            case .processing:
                MeetingProcessingView(controller: controller)
            case .idle:
                if let meeting = controller.finished {
                    MeetingDetailView(controller: controller, meeting: meeting)
                        .id(meeting.id)
                } else {
                    MeetingEmptyView(controller: controller)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}

// MARK: - Setup

private struct MeetingSetupView: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var prefs = Preferences.shared
    @State private var newParticipant = ""

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $controller.draft.title, prompt: Text(MeetingController.defaultTitle()))
                    .font(.title3)
                if controller.draft.calendarEventId != nil {
                    Label("From your calendar", systemImage: "calendar").font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Participants") {
                if !controller.draft.participants.isEmpty {
                    MeetingFlowLayout {
                        ForEach(controller.draft.participants, id: \.self) { name in
                            MeetingChip(text: name) { controller.draft.participants.removeAll { $0 == name } }
                        }
                    }
                    .padding(.vertical, 2)
                }
                TextField("Add someone", text: $newParticipant)
                    .onSubmit(addParticipant)
            }
            Section {
                Label(prefs.meetingSystemAudio
                      ? "Records your microphone and the call's audio. Nothing but the transcript is kept."
                      : "Records your microphone only (system audio is off in Settings).",
                      systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel") { controller.cancelSetup() }
                    .keyboardShortcut(.cancelAction)
                Button("Start recording") {
                    addParticipant()
                    controller.beginRecording()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(.bar)
        }
    }

    private func addParticipant() {
        let name = newParticipant.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !controller.draft.participants.contains(name) { controller.draft.participants.append(name) }
        newParticipant = ""
    }
}

// MARK: - Live

private struct MeetingLiveView: View {
    @ObservedObject var controller: MeetingController
    @State private var note = ""
    @State private var noteSaved = false
    @State private var followTranscript = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            transcript
            Divider()
            footer.padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(Color.red).frame(width: 10, height: 10)
                Text(controller.draft.title).font(.title2.weight(.semibold)).lineLimit(2)
                Spacer()
                if let since = controller.startedAt {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(MeetingController.timestamp(ms: Int64(context.date.timeIntervalSince(since) * 1000)))
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            MeetingParticipants(names: controller.draft.participants)
            VStack(spacing: 6) {
                MeetingLevelBar(label: "Me", level: controller.micLevel)
                MeetingLevelBar(label: "Others", level: controller.systemLevel, active: controller.systemAudioNote == nil)
            }
            if let note = controller.systemAudioNote {
                MeetingBanner(
                    text: note,
                    action: Preferences.shared.meetingSystemAudio
                        ? ("Open Screen Recording settings", MeetingPermissions.openScreenRecordingSettings) : nil
                )
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if controller.segments.isEmpty {
                        Text("The transcript appears here as people speak.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(controller.segments, id: \.id) { MeetingSegmentRow(segment: $0).id($0.id) }
                }
                .padding(16)
            }
            .onChange(of: controller.segments.count) {
                guard followTranscript, let last = controller.segments.last else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Quick note — saved with this meeting", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveNote)
                if noteSaved {
                    Label("Saved", systemImage: "checkmark").foregroundStyle(.green).transition(.opacity)
                }
                Button("Add note", action: saveNote).disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Toggle("Follow transcript", isOn: $followTranscript).toggleStyle(.checkbox)
                Spacer()
                Button {
                    controller.stop()
                } label: {
                    Label("Stop & summarize", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
            }
        }
    }

    private func saveNote() {
        let text = note
        controller.addQuickNote(text) { ok in
            if ok {
                note = ""
                withAnimation { noteSaved = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { noteSaved = false } }
            } else {
                controller.error = "Couldn't save the note."
            }
        }
    }
}

// MARK: - Processing and empty

private struct MeetingProcessingView: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                ProgressView()
                Text("Transcribing the last few seconds and writing the summary…").foregroundStyle(.secondary)
                Text("This can take a minute with a local model.").font(.callout).foregroundStyle(.tertiary)
            }
            .padding(24)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(controller.segments, id: \.id) { MeetingSegmentRow(segment: $0) }
                }
                .padding(16)
            }
        }
    }
}

private struct MeetingWaitingView: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MeetingEmptyView: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.wave.2").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No meeting in progress").font(.title3)
            Text("FnSpeak records your mic and the call, transcribes it on this Mac, and writes a summary with action items.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            HStack {
                Button("Past meetings…") { controller.showList() }
                Button("Start meeting") { controller.requestStart() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
