import SwiftUI

// FnSpeak's own controls, drawn from the design kit's roles. Nothing here
// uses a system control's look: shapes, borders and states are ours, so a
// new skin changes all of them at once.
//
// Each control takes an optional `KitState` so the gallery can show a state
// that otherwise needs a mouse or keyboard. Real screens leave it nil.

/// A state a control can be drawn in for the gallery.
enum KitState {
    case hover, pressed, focused
}

// MARK: - Buttons

/// The app's button. One primary per screen: the thing most people came to do.
struct KitButtonStyle: ButtonStyle {
    enum Kind {
        /// The main action. Accent fill.
        case primary
        /// Everything else. Raised fill with a hairline.
        case secondary
        /// A low-key action inside a row or a header. No fill until hovered.
        case quiet
        /// Deletes or signs out. Says so in the critical colour.
        case destructive
    }

    enum Size {
        case regular, small
    }

    var kind: Kind = .secondary
    var size: Size = .regular
    var showing: KitState?

    func makeBody(configuration: Configuration) -> some View {
        // A button marked destructive looks it, whatever style it was given.
        let kind = configuration.role == .destructive && self.kind != .primary ? Kind.destructive : self.kind
        return Face(kind: kind, size: size, pressed: configuration.isPressed, showing: showing, label: configuration.label)
    }

    private struct Face<Label: View>: View {
        let kind: Kind
        let size: Size
        let pressed: Bool
        let showing: KitState?
        let label: Label
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovering = false

        private var isPressed: Bool { pressed || showing == .pressed }
        private var isHovering: Bool { hovering || showing == .hover }
        private var isFocused: Bool { focused || showing == .focused }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            label
                .font(.system(size: size == .regular ? 13 : 12, weight: .medium))
                .foregroundStyle(ink)
                .padding(.horizontal, size == .regular ? 14 : 10)
                .frame(height: size == .regular ? 30 : 24)
                .background(shape.fill(fill))
                // Hover and press darken or lighten whatever the fill is.
                .overlay(shape.fill(Theme.text.opacity(isPressed ? 0.12 : isHovering ? 0.06 : 0)))
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .overlay(shape.inset(by: -3).strokeBorder(Theme.accent.opacity(isFocused ? 0.55 : 0), lineWidth: 2))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }

        private var ink: Color {
            switch kind {
            case .primary: return Theme.onAccent
            case .secondary, .quiet: return Theme.text
            case .destructive: return Theme.critical
            }
        }

        private var fill: Color {
            switch kind {
            case .primary: return Theme.accent
            case .secondary, .destructive: return Theme.raised
            case .quiet: return .clear
            }
        }

        private var border: Color {
            switch kind {
            case .primary, .quiet: return .clear
            case .secondary, .destructive: return Theme.line
            }
        }
    }
}

extension ButtonStyle where Self == KitButtonStyle {
    static var kitPrimary: KitButtonStyle { KitButtonStyle(kind: .primary) }
    static var kit: KitButtonStyle { KitButtonStyle(kind: .secondary) }
    static var kitQuiet: KitButtonStyle { KitButtonStyle(kind: .quiet) }
    static var kitDestructive: KitButtonStyle { KitButtonStyle(kind: .destructive) }
}

// MARK: - Switch and checkbox

/// An on/off switch that takes effect straight away.
struct KitSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Space.m) {
            configuration.label
            Spacer(minLength: Theme.Space.m)
            Knob(on: configuration.isOn)
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }

    struct Knob: View {
        let on: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            Capsule()
                .fill(on ? Theme.accent : Theme.textFaint.opacity(0.4))
                .frame(width: 34, height: 20)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                        .padding(2)
                }
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Capsule())
        }
    }
}

/// A tick box, for a choice that is saved with others or sits in a list.
struct KitCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: Theme.Space.s) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(configuration.isOn ? Theme.accent : Theme.raised)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(configuration.isOn ? Color.clear : Theme.line, lineWidth: 1))
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .opacity(configuration.isOn ? 1 : 0)
                    }
                    .frame(width: 16, height: 16)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == KitSwitchStyle {
    static var kit: KitSwitchStyle { KitSwitchStyle() }
}

extension ToggleStyle where Self == KitCheckboxStyle {
    static var kitCheckbox: KitCheckboxStyle { KitCheckboxStyle() }
}

// MARK: - Text field

/// A one-line text field.
struct KitField: View {
    let prompt: String
    @Binding var text: String
    var symbol: String?
    var showing: KitState?
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        let active = focused || showing == .focused
        HStack(spacing: Theme.Space.s) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.textFaint)
            }
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.textFaint))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .focused($focused)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(shape.fill(Theme.raised))
        .overlay(shape.strokeBorder(active ? Theme.accent : Theme.line, lineWidth: active ? 1.5 : 1))
        .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: - Choosing one of a few

/// A row of options where one is picked and all are visible. Up to about four.
struct KitSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Theme.text : Theme.textSoft)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.small - 1, style: .continuous)
                                .fill(selected ? Theme.raised : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.small - 1, style: .continuous)
                                .strokeBorder(selected ? Theme.line : Color.clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small + 1, style: .continuous).fill(Theme.sunk))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small + 1, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// A pull-down for one choice among many. The list it opens is the system's.
struct KitMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button(option.label) { selection = option.value }
            }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Text(options.first { $0.value == selection }?.label ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Progress and status

/// How far along something is, from 0 to 1.
struct KitProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(Theme.line)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.accent).frame(width: proxy.size.width * min(max(value, 0), 1))
                }
        }
        .frame(height: 6)
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

/// A two-word verdict beside something: its state, with an icon so the
/// colour is never the only signal.
struct KitTag: View {
    enum Kind {
        case good, warning, critical, neutral
    }

    let text: String
    var kind: Kind = .neutral

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private var color: Color {
        switch kind {
        case .good: return Theme.good
        case .warning: return Theme.warning
        case .critical: return Theme.critical
        case .neutral: return Theme.textSoft
        }
    }

    private var symbol: String {
        switch kind {
        case .good: return "checkmark"
        case .warning: return "exclamationmark"
        case .critical: return "xmark"
        case .neutral: return "circle"
        }
    }
}

// MARK: - Rows and sections

/// A group of rows under a heading: the kit's replacement for a system
/// grouped form section. Rows are divided by hairlines automatically.
struct KitSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let title {
                Text(title).font(Theme.Fonts.heading).foregroundStyle(Theme.text)
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(Divided()) { content }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            if let footer {
                Text(footer).font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
    }

    /// Lays children out with a hairline between each pair.
    private struct Divided: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            let last = children.last?.id
            ForEach(children) { child in
                // Whatever is put in a section becomes a row: same inset,
                // same minimum height, text starting at the same edge.
                child
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                if child.id != last {
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, Theme.Space.l)
                }
            }
        }
    }
}

/// One setting or fact: what it is on the left, its control or value on the right.
struct KitRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var symbol: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSoft)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.m)
            trailing
        }
    }
}

extension KitRow where Trailing == EmptyView {
    init(title: String, detail: String? = nil, symbol: String? = nil) {
        self.init(title: title, detail: detail, symbol: symbol) { EmptyView() }
    }
}

// MARK: - Page header

/// The top of every page: its title, a line about it, and that page's
/// actions on the right. It replaces the system toolbar, so nothing but
/// the window's own buttons sits above it.
struct KitHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Fonts.title).foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle).font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.l)
            HStack(spacing: Theme.Space.s) { actions }
        }
    }
}

extension View {
    /// Put a kit header above a page that fills its pane, such as a list
    /// with a detail beside it. The page's buttons live here, so nothing
    /// is handed to the system toolbar.
    func kitHeader<Actions: View>(_ title: String, @ViewBuilder actions: () -> Actions) -> some View {
        KitHeaderPage(header: KitHeader(title: title, actions: actions), page: self)
    }
}

private struct KitHeaderPage<Actions: View, Page: View>: View {
    let header: KitHeader<Actions>
    let page: Page
    @Environment(\.inPanel) private var inPanel
    @Environment(\.pageTopInset) private var topInset

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.gutter)
                .padding(.top, topInset)
                .padding(.bottom, Theme.Space.m)
                .background(Theme.page)
            Rectangle().fill(Theme.line).frame(height: 1)
            page
        }
        // On its own the page runs up behind the title bar; in the main
        // window's panel it stays under the header.
        .ignoresSafeArea(edges: inPanel ? [] : .top)
    }
}

extension KitHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Forms

/// A settings page: sections down a scrolling column, with the kit's look
/// set as the default for every button, switch, field and labelled value
/// inside, so pages don't style their controls one by one.
struct KitForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                content
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .buttonStyle(KitButtonStyle(kind: .secondary, size: .small))
        .toggleStyle(.kit)
        .textFieldStyle(KitTextFieldStyle())
        .labeledContentStyle(KitLabeledStyle())
    }
}

/// A label on the left and its value or control on the right.
struct KitLabeledStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            configuration.label.foregroundStyle(Theme.text)
            Spacer(minLength: Theme.Space.m)
            configuration.content
                .foregroundStyle(Theme.textSoft)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// The kit's look for a text field that a page builds with `TextField`.
struct KitTextFieldStyle: TextFieldStyle {
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        Wrapped(field: configuration)
    }

    private struct Wrapped: View {
        let field: TextField<_Label>
        @FocusState private var focused: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            field
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(shape.fill(Theme.raised))
                .overlay(shape.strokeBorder(focused ? Theme.accent : Theme.line, lineWidth: focused ? 1.5 : 1))
                .opacity(enabled ? 1 : 0.45)
        }
    }
}

/// A choice with its name on the left and the system's pull-down, radio
/// group or segments on the right, whichever style the page asks for.
struct KitPicker<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    /// Set on pickers stacked in one section, so they line up on both
    /// sides. Left alone, each is as wide as its own choice.
    var width: CGFloat?
    @ViewBuilder var content: Content

    init(_ title: String, selection: Binding<Selection>, width: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self._selection = selection
        self.width = width
        self.content = content()
    }

    var body: some View {
        LabeledContent(title) {
            if let width {
                Picker(title, selection: $selection) { content }
                    .labelsHidden()
                    .frame(width: width)
            } else {
                Picker(title, selection: $selection) { content }
                    .labelsHidden()
                    .fixedSize()
            }
        }
    }
}

// MARK: - Tooltip

/// A hover label in the kit's own style, for icon-only controls. It shows
/// after a beat, beside the control, and never takes a click.
struct KitTip: ViewModifier {
    enum Side { case above, below, left, right }
    /// Which end of the control the label lines up with, so one near the
    /// edge of its window doesn't run off it.
    enum Anchor { case leading, center, trailing }

    let text: String
    var side: Side = .below
    var anchor: Anchor = .center
    /// On the pill, which is always black whatever the app's appearance.
    var onDark = false
    /// A shortcut, set in bold after the text.
    var key: String?
    /// How far the label stands off the control.
    var gap: CGFloat = 6

    /// Set by a group of controls that share one hover, so only one of
    /// their labels is ever up. Nil means this control tracks its own.
    var active: Bool?

    @State private var hovering = false
    @State private var shown = false
    @State private var token = 0

    func body(content: Content) -> some View {
        content
            .onHover { if active == nil { hovering = $0 } }
            .onChange(of: active ?? hovering, initial: true) { _, on in
                token += 1
                guard on else { shown = false; return }
                let mine = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if mine == token { shown = true }
                }
            }
            // A point on the control's edge, with the label hung off its far
            // side: the label starts a gap beyond the control whatever size
            // either of them is.
            .overlay(alignment: edge.outer) {
                Color.clear.frame(width: 0, height: 0)
                    .overlay(alignment: edge.inner) {
                        if shown {
                            label
                                .padding(edge.pad, gap)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
            }
            .zIndex(shown ? 10 : 0)
            .animation(.easeOut(duration: 0.1), value: shown)
            .accessibilityHint(text)
    }

    /// Where the anchor sits on the control, which corner of the label
    /// meets it, and which side of the label the gap goes on.
    private var edge: (outer: Alignment, inner: Alignment, pad: Edge.Set) {
        switch side {
        case .above:
            return (Alignment(horizontal: horizontal, vertical: .top), Alignment(horizontal: horizontal, vertical: .bottom), .bottom)
        case .below:
            return (Alignment(horizontal: horizontal, vertical: .bottom), Alignment(horizontal: horizontal, vertical: .top), .top)
        case .left:
            return (.leading, .trailing, .trailing)
        case .right:
            return (.trailing, .leading, .leading)
        }
    }

    private var horizontal: HorizontalAlignment {
        switch anchor {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    /// On the pill it's a pill of its own: black, outlined, a size up.
    private var label: some View {
        let shape = onDark ? AnyInsettableShape(Capsule()) : AnyInsettableShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        let size: CGFloat = onDark ? 13 : 11
        return HStack(spacing: 5) {
            Text(text).font(.system(size: size, weight: .medium))
            if let key { Text(key).font(.system(size: size, weight: .bold)) }
        }
        .foregroundStyle(onDark ? Color.white : Theme.page)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, onDark ? 13 : 8)
        .padding(.vertical, onDark ? 7 : 4)
        .background(shape.fill(onDark ? Color.black : Theme.text))
        .overlay(shape.strokeBorder(Color.white.opacity(onDark ? 0.9 : 0), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 1)
    }
}

extension View {
    /// A hover label in the kit's style. Use it where a native tooltip
    /// wouldn't show (floating panels) or wouldn't match.
    func kitTip(_ text: String, side: KitTip.Side = .below, anchor: KitTip.Anchor = .center, onDark: Bool = false, key: String? = nil, gap: CGFloat = 6, active: Bool? = nil) -> some View {
        modifier(KitTip(text: text, side: side, anchor: anchor, onDark: onDark, key: key, gap: gap, active: active))
    }
}

/// One insettable shape or another, chosen at run time.
struct AnyInsettableShape: InsettableShape {
    private let make: @Sendable (CGRect, CGFloat) -> Path

    init<S: InsettableShape>(_ shape: S) {
        make = { rect, inset in shape.inset(by: inset).path(in: rect) }
    }

    private var amount: CGFloat = 0

    func path(in rect: CGRect) -> Path { make(rect, amount) }

    func inset(by amount: CGFloat) -> AnyInsettableShape {
        var copy = self
        copy.amount += amount
        return copy
    }
}
