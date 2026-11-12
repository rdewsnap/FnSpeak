import AppKit
import SwiftUI

/// Every piece of the design kit on one sheet, in each of its states, for
/// reviewing a skin before it reaches the app. Not shown to users: it is
/// drawn to image files by `FNSPEAK_KIT_GALLERY=<folder>` (see DevTools).
struct KitGallery: View {
    enum Sheet: String, CaseIterable {
        case foundations, controls, patterns
        /// A little of everything, small enough to compare skins at a glance.
        case sample
    }

    let sheet: Sheet

    @State private var on = true
    @State private var off = false
    @State private var empty = ""
    @State private var filled = "Priya Raman"
    @State private var mode = "local"
    @State private var engine = "whisper"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            switch sheet {
            case .foundations: foundations
            case .controls: controls
            case .patterns: patterns
            case .sample: sample
            }
        }
        .padding(Theme.Space.xxl)
        .frame(width: 760, alignment: .leading)
        .background(Theme.page)
        .skinned()
    }

    // MARK: Foundations

    @ViewBuilder private var foundations: some View {
        KitHeader(title: "Foundations", subtitle: "The colours, type, spacing and corners everything else is built from.")

        block("Surfaces") {
            HStack(spacing: Theme.Space.m) {
                swatch("page", Theme.page, "Behind everything")
                swatch("sunk", Theme.sunk, "Sidebar, wells")
                swatch("raised", Theme.raised, "Cards, controls")
            }
        }

        block("Text and lines") {
            HStack(spacing: Theme.Space.m) {
                swatch("text", Theme.text, "Titles, main lines")
                swatch("textSoft", Theme.textSoft, "Supporting lines")
                swatch("textFaint", Theme.textFaint, "Captions")
                swatch("line", Theme.line, "Edges, dividers")
            }
        }

        block("Accent and state") {
            HStack(spacing: Theme.Space.m) {
                swatch("accent", Theme.accent, "One per screen")
                swatch("highlight", Theme.highlight, "Marker wash")
                swatch("good", Theme.good, "Allowed, stays here")
                swatch("warning", Theme.warning, "Needs a look")
                swatch("critical", Theme.critical, "Failed, deletes")
            }
        }

        block("Type") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                sample("display", Text("Hold fn and talk.").font(Theme.Fonts.display))
                sample("title", Text("Vocabulary").font(Theme.Fonts.title))
                sample("stat", Text("151").font(Theme.Fonts.stat))
                sample("heading", Text("Recent").font(Theme.Fonts.heading))
                sample("body", Text("Send it to Priya on Friday.").font(Theme.Fonts.body))
                sample("support", Text("last week · Notes · 7 words").font(Theme.Fonts.support).foregroundStyle(Theme.textSoft))
                sample("caption", Text("Resets December 1").font(Theme.Fonts.caption).foregroundStyle(Theme.textFaint))
                sample("mono", Text("fnspeak://dictate").font(Theme.Fonts.mono))
            }
        }

        block("Space") {
            HStack(alignment: .bottom, spacing: Theme.Space.l) {
                ForEach([("xs", Theme.Space.xs), ("s", Theme.Space.s), ("m", Theme.Space.m), ("l", Theme.Space.l), ("xl", Theme.Space.xl), ("xxl", Theme.Space.xxl)], id: \.0) { name, value in
                    VStack(spacing: 6) {
                        Rectangle().fill(Theme.accent.opacity(0.35)).frame(width: value, height: value)
                        Text("\(name) \(Int(value))").font(Theme.Fonts.caption).foregroundStyle(Theme.textSoft)
                    }
                }
            }
        }

        block("Corners") {
            HStack(spacing: Theme.Space.l) {
                ForEach([("small", Theme.Radius.small), ("medium", Theme.Radius.medium), ("large", Theme.Radius.large)], id: \.0) { name, value in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: value, style: .continuous)
                            .fill(Theme.raised)
                            .overlay(RoundedRectangle(cornerRadius: value, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                            .frame(width: 84, height: 52)
                        Text("\(name) \(Int(value))").font(Theme.Fonts.caption).foregroundStyle(Theme.textSoft)
                    }
                }
            }
        }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        KitHeader(title: "Controls", subtitle: "Each one at rest, hovered, pressed, focused and switched off.")

        block("Buttons") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                states("Primary", .primary)
                states("Secondary", .secondary)
                states("Quiet", .quiet)
                states("Destructive", .destructive)
                HStack(spacing: Theme.Space.m) {
                    label("Small")
                    Button("Save") {}.buttonStyle(KitButtonStyle(kind: .primary, size: .small))
                    Button("Cancel") {}.buttonStyle(KitButtonStyle(kind: .secondary, size: .small))
                    Button("Learn more") {}.buttonStyle(KitButtonStyle(kind: .quiet, size: .small))
                }
            }
        }

        block("Switch and checkbox") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.xl) {
                    KitSwitchStyle.Knob(on: true)
                    KitSwitchStyle.Knob(on: false)
                    KitSwitchStyle.Knob(on: true).disabled(true)
                    KitSwitchStyle.Knob(on: false).disabled(true)
                }
                HStack(spacing: Theme.Space.xl) {
                    Toggle("Remove filler words", isOn: $on).toggleStyle(.kitCheckbox)
                    Toggle("Play a sound", isOn: $off).toggleStyle(.kitCheckbox)
                }
                .font(.system(size: 13))
            }
        }

        block("Text field") {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                KitField(prompt: "you@example.com", text: $empty).frame(width: 200)
                KitField(prompt: "", text: $filled, showing: .focused).frame(width: 200)
                KitField(prompt: "Search notes", text: $empty, symbol: "magnifyingglass").frame(width: 200)
            }
        }

        block("Choosing") {
            HStack(spacing: Theme.Space.xl) {
                KitSegmented(selection: $mode, options: [("raw", "Raw"), ("filter", "Filter"), ("local", "Local"), ("cloud", "Cloud")])
                KitMenu(selection: $engine, options: [("whisper", "Whisper large v3 turbo"), ("parakeet", "Parakeet")])
            }
        }

        block("Progress") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                KitProgress(value: 0.13).frame(width: 320)
                KitProgress(value: 0.62).frame(width: 320)
                KitProgress(value: 1).frame(width: 320)
            }
        }

        block("Status tags") {
            HStack(spacing: Theme.Space.m) {
                KitTag(text: "Stays here", kind: .good)
                KitTag(text: "Sent for cleanup", kind: .warning)
                KitTag(text: "Couldn't connect", kind: .critical)
                KitTag(text: "Not set up", kind: .neutral)
            }
        }

        block("Keys") {
            HStack(spacing: Theme.Space.m) {
                Keycap(label: "fn")
                Keycap(label: "esc")
                Keycap(label: "⌃⌥Z")
                Keycap(label: "fn", size: 22)
            }
        }
    }

    // MARK: Patterns

    @ViewBuilder private var patterns: some View {
        KitHeader(title: "Vocabulary", subtitle: "A page header with its actions, then sections of rows.") {
            Button("Import…") {}.buttonStyle(.kit)
            Button("Add a term") {}.buttonStyle(.kitPrimary)
        }

        KitSection(title: "Dictation", footer: "Changes apply to the next thing you say.") {
            KitRow(title: "Remove filler words", detail: "Um, uh, like and you know.", symbol: "scissors") {
                KitSwitchStyle.Knob(on: true)
            }
            KitRow(title: "Speech model", symbol: "waveform") {
                KitMenu(selection: $engine, options: [("whisper", "Whisper large v3 turbo"), ("parakeet", "Parakeet")])
            }
            KitRow(title: "Cleanup", detail: "Where the tidying happens.", symbol: "wand.and.stars") {
                KitSegmented(selection: $mode, options: [("filter", "Filter"), ("local", "Local"), ("cloud", "Cloud")])
            }
            KitRow(title: "Dictation key", symbol: "keyboard") {
                Keycap(label: "fn")
                Button("Change") {}.buttonStyle(KitButtonStyle(kind: .secondary, size: .small))
            }
        }

        KitSection(title: "Where your data goes") {
            KitRow(title: "Your voice", detail: "Turned into text on this Mac and thrown away.", symbol: "mic") {
                KitTag(text: "Never leaves", kind: .good)
            }
            KitRow(title: "Dictation text", detail: "Sent to be tidied, with any vocabulary it mentions.", symbol: "text.bubble") {
                KitTag(text: "Sent for cleanup", kind: .warning)
            }
        }

        KitSection(title: "Connectors") {
            KitRow(title: "Google Calendar", detail: "Reminders before meetings, and the link to join.", symbol: "calendar") {
                KitTag(text: "Connected", kind: .good)
                Button("Disconnect") {}.buttonStyle(KitButtonStyle(kind: .quiet, size: .small))
            }
            KitRow(title: "Outlook Calendar", detail: "Reminders before meetings, and the link to join.", symbol: "calendar") {
                Button("Connect") {}.buttonStyle(KitButtonStyle(kind: .secondary, size: .small))
            }
        }

        KitSection(title: "Account") {
            KitRow(title: "Plan", detail: "128 of 1,000 used this month. Resets December 1.") {
                KitProgress(value: 0.128).frame(width: 120)
            }
            KitRow(title: "Signed in as you@example.com") {
                Button("Sign out") {}.buttonStyle(KitButtonStyle(kind: .destructive, size: .small))
            }
        }

        block("Cards") {
            HStack(spacing: Theme.Space.m) {
                ForEach([("1,284", "words this week"), ("151", "words a minute"), ("4 min", "saved over typing")], id: \.1) { figure, caption in
                    Card {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(figure).font(Theme.Fonts.stat)
                            Text(caption).font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
                        }
                    }
                }
            }
        }

        block("Sidebar rows") {
            VStack(spacing: 1) {
                SidebarRow(title: "Home", symbol: "house", selected: true, external: false) {}
                SidebarRow(title: "Meetings", symbol: "record.circle", selected: false, external: false) {}
                SidebarRow(title: "Help", symbol: "questionmark.circle", selected: false, external: true) {}
            }
            .padding(Theme.Space.s)
            .frame(width: 208)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.sunk))
        }
    }

    // MARK: Sample

    @ViewBuilder private var sample: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("FnSpeak").font(Theme.Fonts.heading).padding(.leading, 8).padding(.bottom, 8)
                SidebarRow(title: "Home", symbol: "house", selected: true, external: false) {}
                SidebarRow(title: "Meetings", symbol: "record.circle", selected: false, external: false) {}
                SidebarRow(title: "Notes", symbol: "note.text", selected: false, external: false) {}
                SidebarRow(title: "Vocabulary", symbol: "book.closed", selected: false, external: false) {}
            }
            .padding(Theme.Space.m)
            .frame(width: 180, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.sunk)

            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("Hold").font(Theme.Fonts.display)
                        Keycap(label: "fn", size: 20)
                        Text("and talk.").font(Theme.Fonts.display)
                    }
                    Text("Ready · Whisper · Local cleanup").font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
                }
                HStack(spacing: Theme.Space.m) {
                    ForEach([("1,284", "words this week"), ("151", "words a minute")], id: \.1) { figure, caption in
                        Card {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(figure).font(Theme.Fonts.stat)
                                Text(caption).font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
                            }
                        }
                    }
                }
                KitSection(title: "Dictation") {
                    KitRow(title: "Remove filler words", detail: "Um, uh, like and you know.", symbol: "scissors") {
                        KitSwitchStyle.Knob(on: true)
                    }
                    KitRow(title: "Cleanup", symbol: "wand.and.stars") {
                        KitSegmented(selection: $mode, options: [("filter", "Filter"), ("local", "Local"), ("cloud", "Cloud")])
                    }
                    KitRow(title: "Google Calendar", detail: "Reminders before meetings.", symbol: "calendar") {
                        KitTag(text: "Connected", kind: .good)
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    Button("Add a term") {}.buttonStyle(.kitPrimary)
                    Button("Import…") {}.buttonStyle(.kit)
                    Button("Learn more") {}.buttonStyle(.kitQuiet)
                    Spacer()
                    KitProgress(value: 0.4).frame(width: 120)
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(-Theme.Space.xxl)
    }

    // MARK: Pieces

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title).font(Theme.Fonts.heading)
            content()
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.Fonts.support).foregroundStyle(Theme.textSoft).frame(width: 84, alignment: .leading)
    }

    private func states(_ name: String, _ kind: KitButtonStyle.Kind) -> some View {
        HStack(spacing: Theme.Space.m) {
            label(name)
            Button("Rest") {}.buttonStyle(KitButtonStyle(kind: kind))
            Button("Hover") {}.buttonStyle(KitButtonStyle(kind: kind, showing: .hover))
            Button("Pressed") {}.buttonStyle(KitButtonStyle(kind: kind, showing: .pressed))
            Button("Focused") {}.buttonStyle(KitButtonStyle(kind: kind, showing: .focused))
            Button("Off") {}.buttonStyle(KitButtonStyle(kind: kind)).disabled(true)
        }
    }

    private func swatch(_ name: String, _ color: Color, _ use: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                .frame(height: 52)
            Text(name).font(.system(size: 12, weight: .medium))
            Text(use).font(Theme.Fonts.caption).foregroundStyle(Theme.textSoft)
        }
        .frame(width: 124, alignment: .leading)
    }

    private func sample(_ name: String, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.l) {
            Text(name).font(Theme.Fonts.caption).foregroundStyle(Theme.textFaint).frame(width: 64, alignment: .leading)
            text
        }
    }
}

extension KitGallery {
    /// Draw each sheet, light and dark, into `directory`, then quit.
    static func render(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.regular)
        var shots: [(Sheet, NSAppearance.Name)] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for sheet in Sheet.allCases { shots.append((sheet, appearance)) }
        }
        func shoot(_ remaining: ArraySlice<(Sheet, NSAppearance.Name)>) {
            guard let (sheet, appearance) = remaining.first else { return NSApp.terminate(nil) }
            let host = NSHostingView(rootView: KitGallery(sheet: sheet))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.backgroundColor = Theme.pageNSColor
            window.contentView = host
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let suffix = appearance == .darkAqua ? "-dark" : ""
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: directory.appendingPathComponent("\(Theme.skin.name)-\(sheet.rawValue)\(suffix).png"))
                }
                window.close()
                shoot(remaining.dropFirst())
            }
        }
        shoot(shots[...])
    }
}
