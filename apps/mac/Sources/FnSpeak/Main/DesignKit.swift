import AppKit
import SwiftUI

/// FnSpeak's design kit.
///
/// Every colour, typeface, space and corner the app draws with comes from
/// here. A `Skin` is one complete set of those choices. `Theme.skin` picks
/// the one in use, so trying a different look means writing another `Skin`
/// and changing that one line. Views never use a hex value, a system
/// background or a font size of their own; they ask `Theme` for a role
/// ("the page", "a raised panel", "a page title") and get whatever the
/// current skin says that is.
///
/// The written guide, with when to use what, is docs/design-kit.md.
struct Skin {
    /// A colour that is one thing in light mode and another in dark.
    struct Pair {
        let light: UInt32
        let dark: UInt32
    }

    // Surfaces, from back to front.
    /// The window behind everything.
    var page: Pair
    /// A step back from the page: the sidebar, wells, code.
    var sunk: Pair
    /// A step forward: cards, keycaps, anything that sits on the page.
    var raised: Pair

    // Text.
    var text: Pair
    /// Supporting lines under a title or beside a value.
    var textSoft: Pair
    /// Captions and anything that should recede.
    var textFaint: Pair

    /// Hairlines: card edges, dividers.
    var line: Pair

    /// The one brand colour: the selected row, the main button, focus.
    var accent: Pair
    /// Text and icons drawn on top of the accent.
    var onAccent: Pair
    /// A marker-pen wash behind a word worth noticing.
    var highlight: Pair

    // State. Never the only signal: pair each with an icon or a word.
    var good: Pair
    var warning: Pair
    var critical: Pair

    /// A short name, for picking the skin with FNSPEAK_SKIN while comparing.
    var name: String
    /// The design of the display face, used for page titles and big numbers.
    var displayDesign: Font.Design
    /// How heavy the display face is set.
    var displayWeight: Font.Weight
    /// Corner radii: small controls, cards, large panels.
    var radius: (small: CGFloat, medium: CGFloat, large: CGFloat)
}

extension Skin {
    /// The look of fnspeak.com: warm paper, near-black ink, serif titles and
    /// one clay accent.
    static let paper = Skin(
        page: Pair(light: 0xfcfcfb, dark: 0x15161a),
        sunk: Pair(light: 0xf3f3f1, dark: 0x101114),
        raised: Pair(light: 0xffffff, dark: 0x1d1e23),
        text: Pair(light: 0x141311, dark: 0xecebe6),
        textSoft: Pair(light: 0x4e4b45, dark: 0xb4b2aa),
        textFaint: Pair(light: 0x6f6c65, dark: 0x8e8c85),
        line: Pair(light: 0xdcdcd8, dark: 0x2d2e34),
        accent: Pair(light: 0xc4532a, dark: 0xe5693d),
        onAccent: Pair(light: 0xffffff, dark: 0x15161a),
        highlight: Pair(light: 0xfff1c2, dark: 0x3a2f1a),
        good: Pair(light: 0x17734b, dark: 0x3fbf88),
        warning: Pair(light: 0x955800, dark: 0xe0a13a),
        critical: Pair(light: 0xc0392b, dark: 0xef6b5e),
        name: "paper",
        displayDesign: .serif,
        displayWeight: .medium,
        radius: (small: 6, medium: 10, large: 14)
    )

    // Shared by the skins below: the same state colours on neutral surfaces.
    private static let states = (
        good: Pair(light: 0x17734b, dark: 0x3fbf88),
        warning: Pair(light: 0x955800, dark: 0xe0a13a),
        critical: Pair(light: 0xc0392b, dark: 0xef6b5e)
    )

    /// No colour at all: black on a neutral white, heavy sans titles. The
    /// accent is the ink itself.
    static let ink = Skin(
        page: Pair(light: 0xfafafa, dark: 0x131315),
        sunk: Pair(light: 0xf1f1f2, dark: 0x0c0c0d),
        raised: Pair(light: 0xffffff, dark: 0x1c1c1f),
        text: Pair(light: 0x111113, dark: 0xf2f2f3),
        textSoft: Pair(light: 0x4a4a50, dark: 0xb5b5bb),
        textFaint: Pair(light: 0x6b6b72, dark: 0x8c8c93),
        line: Pair(light: 0xdedee2, dark: 0x2c2c31),
        accent: Pair(light: 0x111113, dark: 0xf2f2f3),
        onAccent: Pair(light: 0xffffff, dark: 0x111113),
        highlight: Pair(light: 0xfff1c2, dark: 0x3a2f1a),
        good: states.good, warning: states.warning, critical: states.critical,
        name: "ink",
        displayDesign: .default,
        displayWeight: .bold,
        radius: (small: 6, medium: 10, large: 14)
    )

    /// A deep green on a soft neutral, semibold sans titles.
    static let pine = Skin(
        page: Pair(light: 0xfbfbf9, dark: 0x121513),
        sunk: Pair(light: 0xf1f2ee, dark: 0x0b0d0c),
        raised: Pair(light: 0xffffff, dark: 0x1a1e1b),
        text: Pair(light: 0x121512, dark: 0xe9ede9),
        textSoft: Pair(light: 0x474d48, dark: 0xaeb6af),
        textFaint: Pair(light: 0x68706a, dark: 0x88908a),
        line: Pair(light: 0xdcdfd9, dark: 0x29302b),
        accent: Pair(light: 0x1d6b50, dark: 0x56c79b),
        onAccent: Pair(light: 0xffffff, dark: 0x0b0d0c),
        highlight: Pair(light: 0xe3f3ea, dark: 0x1c3329),
        good: states.good, warning: states.warning, critical: states.critical,
        name: "pine",
        displayDesign: .default,
        displayWeight: .semibold,
        radius: (small: 6, medium: 10, large: 14)
    )

    /// An ink blue on a cool white, bold sans titles.
    static let cobalt = Skin(
        page: Pair(light: 0xfafbfd, dark: 0x101218),
        sunk: Pair(light: 0xf0f2f7, dark: 0x0a0b10),
        raised: Pair(light: 0xffffff, dark: 0x191c25),
        text: Pair(light: 0x0f1220, dark: 0xe8eaf2),
        textSoft: Pair(light: 0x444a5c, dark: 0xaab0c2),
        textFaint: Pair(light: 0x646b80, dark: 0x868da3),
        line: Pair(light: 0xdadee8, dark: 0x272b38),
        accent: Pair(light: 0x2a45d6, dark: 0x8296ff),
        onAccent: Pair(light: 0xffffff, dark: 0x0a0b10),
        highlight: Pair(light: 0xe4e9ff, dark: 0x1d2547),
        good: states.good, warning: states.warning, critical: states.critical,
        name: "cobalt",
        displayDesign: .default,
        displayWeight: .bold,
        radius: (small: 6, medium: 10, large: 14)
    )

    /// Highlighter yellow with black type on it, on a neutral white, with
    /// the heaviest sans titles. Takes its colour from the marker wash.
    static let marker = Skin(
        page: Pair(light: 0xfafafa, dark: 0x131315),
        sunk: Pair(light: 0xf1f1f2, dark: 0x0c0c0d),
        raised: Pair(light: 0xffffff, dark: 0x1c1c1f),
        text: Pair(light: 0x111113, dark: 0xf2f2f3),
        textSoft: Pair(light: 0x4a4a50, dark: 0xb5b5bb),
        textFaint: Pair(light: 0x6b6b72, dark: 0x8c8c93),
        line: Pair(light: 0xdedee2, dark: 0x2c2c31),
        accent: Pair(light: 0xf5b301, dark: 0xffc928),
        onAccent: Pair(light: 0x141311, dark: 0x141311),
        highlight: Pair(light: 0xfff1c2, dark: 0x3a2f1a),
        good: states.good, warning: states.warning, critical: states.critical,
        name: "marker",
        displayDesign: .default,
        displayWeight: .heavy,
        radius: (small: 6, medium: 10, large: 14)
    )

    static let all: [Skin] = [.paper, .ink, .pine, .cobalt, .marker]
}

extension Theme {
    /// The skin in use. Change this line to reskin the app.
    static let skin: Skin = chosenForComparison ?? .ink

    /// A skin named in FNSPEAK_SKIN, for looking at alternatives side by
    /// side without editing this file.
    private static let chosenForComparison: Skin? = {
        let name = ProcessInfo.processInfo.environment["FNSPEAK_SKIN"]
        return Skin.all.first { $0.name == name }
    }()

    // MARK: Colour roles

    static let page = color(skin.page)
    static let sunk = color(skin.sunk)
    static let raised = color(skin.raised)
    static let text = color(skin.text)
    static let textSoft = color(skin.textSoft)
    static let textFaint = color(skin.textFaint)
    static let line = color(skin.line)
    static let accent = color(skin.accent)
    static let onAccent = color(skin.onAccent)
    static let highlight = color(skin.highlight)
    static let good = color(skin.good)
    static let warning = color(skin.warning)
    static let critical = color(skin.critical)

    /// The page colour for AppKit, so a window's title bar matches its content.
    static let pageNSColor = nsColor(skin.page)
    /// The sidebar's colour for AppKit, behind the main window's header.
    static let sunkNSColor = nsColor(skin.sunk)

    // MARK: Type roles

    /// Text styles by job. Sizes are in points and don't scale with the
    /// window; body text follows the system's size so it respects the
    /// user's settings.
    enum Fonts {
        /// The one big line on a page, such as Home's greeting.
        static let display = Font.system(size: 30, weight: Theme.skin.displayWeight, design: Theme.skin.displayDesign)
        /// A page's title.
        static let title = Font.system(size: 24, weight: Theme.skin.displayWeight, design: Theme.skin.displayDesign)
        /// A figure worth reading from across the room.
        static let stat = Font.system(size: 26, weight: Theme.skin.displayWeight, design: Theme.skin.displayDesign)
        /// The label above a group of rows.
        static let heading = Font.system(size: 13, weight: .semibold)
        /// A row's main line.
        static let body = Font.body
        /// The line under it.
        static let support = Font.callout
        static let caption = Font.caption
        /// Keys, codes and anything typed exactly.
        static let mono = Font.system(.callout, design: .monospaced)
    }

    // MARK: Space and shape

    /// The spacing scale. Pick the nearest step; don't invent values between.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 36
    }

    enum Radius {
        /// Rows, chips, small controls.
        static let small = Theme.skin.radius.small
        /// Cards and wells.
        static let medium = Theme.skin.radius.medium
        /// Sheets and the largest panels.
        static let large = Theme.skin.radius.large
    }

    // MARK: Plumbing

    private static func nsColor(_ pair: Skin.Pair) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? pair.dark : pair.light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1
            )
        }
    }

    private static func color(_ pair: Skin.Pair) -> Color {
        Color(nsColor: nsColor(pair))
    }
}

extension View {
    /// Put a window's root view in the kit's colours: page behind it, the
    /// accent on its controls, the kit's ink as its text.
    func skinned() -> some View {
        self.tint(Theme.accent)
            .foregroundStyle(Theme.text)
            // The kit's controls are the default for everything inside, so a
            // page only names a style when it wants something else.
            .buttonStyle(KitButtonStyle(kind: .secondary, size: .small))
            .toggleStyle(.kit)
            .textFieldStyle(KitTextFieldStyle())
            .labeledContentStyle(KitLabeledStyle())
    }
}
