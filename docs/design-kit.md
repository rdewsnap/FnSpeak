# FnSpeak design kit

How FnSpeak looks, and how to change it. The source of truth is
`apps/mac/Sources/FnSpeak/Main/DesignKit.swift`. This page explains the
choices and the rules for using them.

## How it's built

A **skin** is one complete set of choices: colours, the display typeface and
its weight, and corner radii. The app uses `Skin.ink`: black type on a
neutral white, heavy sans titles, and no colour accent. Four others are kept
beside it for comparison: `paper` (the website's warm look with serif titles
and a clay accent), `pine`, `cobalt` and `marker`.

**Roles** are what views ask for. A view never says "white" or "#c4532a". It
says `Theme.raised` or `Theme.accent`, and gets whatever the current skin
says that is.

To change the look, pick or write another `Skin` and change one line:

```swift
static let skin: Skin = chosenForComparison ?? .ink
```

To look at a skin without editing anything, run the app with `FNSPEAK_SKIN`
set to its name. With `FNSPEAK_KIT_GALLERY` set to a folder as well, the app
draws the kit's gallery sheets there in that skin and quits.

Every screen follows. Nothing else needs editing, provided the rules at the
bottom of this page have been kept.

## Colour

Each colour has a light and a dark value. Dark mode is chosen by hand for
each one, not produced by inverting.

| Role | Light | Dark | Use it for |
|---|---|---|---|
| `page` | `#fafafa` | `#131315` | The window, behind everything |
| `sunk` | `#f1f1f2` | `#0c0c0d` | The sidebar, wells, code |
| `raised` | `#ffffff` | `#1c1c1f` | Cards, controls, anything sitting on the page |
| `text` | `#111113` | `#f2f2f3` | Titles and the main line of a row |
| `textSoft` | `#4a4a50` | `#b5b5bb` | The line under a title, values beside a label |
| `textFaint` | `#6b6b72` | `#8c8c93` | Captions, timestamps |
| `line` | `#dedee2` | `#2c2c31` | Card edges and dividers, 1 point |
| `accent` | `#111113` | `#f2f2f3` | The selected row, the main button, focus. In Ink this is the text colour itself |
| `onAccent` | `#ffffff` | `#111113` | Text and icons on top of the accent |
| `highlight` | `#fff1c2` | `#3a2f1a` | A marker-pen wash behind a word |
| `good` | `#17734b` | `#3fbf88` | Allowed, connected, stays on this Mac |
| `warning` | `#955800` | `#e0a13a` | Needs attention, leaves this Mac |
| `critical` | `#c0392b` | `#ef6b5e` | Failed, destructive |

These are Ink's values. Each skin in `DesignKit.swift` has its own.

Rules:

- **One accent.** It marks the single most important thing on a screen: where
  you are, or what to press. If two things on a screen are both accent, one
  of them shouldn't be.
- **Surfaces stack in one direction.** `sunk` is behind `page`, `raised` is in
  front. Don't put a `sunk` panel inside a `raised` card.
- **State colours never work alone.** Pair `good`, `warning` and `critical`
  with an icon or a word, so the meaning survives for people who can't tell
  the colours apart.
- **Text contrast, measured.** In Ink, `text`, `textSoft` and `textFaint`
  clear 4.5:1 on `page`, `sunk` and `raised` in both modes (the lowest is
  4.7:1), and the label on a primary button is over 16:1.
- **With no colour accent, colour means state.** Green, amber and red appear
  only as `good`, `warning` and `critical`, so they stand out when they do.
- **Check a new skin before using it.** `paper`'s clay accent is 4.4:1 as
  small text on its page, and `marker`'s yellow is 1.8:1 on a light page, so
  both need the accent kept to fills.

## Type

One family in Ink: the system sans (San Francisco) throughout, with titles
set bold. A skin chooses the display face's design and weight, so `paper`
sets the same roles in the system serif at medium weight.

| Role | Size and weight | Use it for |
|---|---|---|
| `Fonts.display` | 30, the skin's display face | The one big line on a page |
| `Fonts.title` | 24, the skin's display face | A page's title |
| `Fonts.stat` | 26, the skin's display face | A figure to read at a glance |
| `Fonts.heading` | 13, semibold | The label above a group of rows |
| `Fonts.body` | system body | A row's main line |
| `Fonts.support` | system callout | The line under it |
| `Fonts.caption` | system caption | Timestamps, fine print |
| `Fonts.mono` | callout, monospaced | Keys, codes, paths |

Rules:

- **The display face is for titles and big numbers only.** Never for
  buttons, labels or running text.
- **One title per page.** Sections under it use `heading`.
- **Sentence case everywhere.** No all-caps labels.
- **Body text follows the system size**, so it respects the user's settings.

## Space

One scale. Pick the nearest step and don't invent values between.

| Step | Points | Typical use |
|---|---|---|
| `Space.xs` | 4 | Between a line and its own sub-line |
| `Space.s` | 8 | Between an icon and its label |
| `Space.m` | 12 | Inside a compact card |
| `Space.l` | 16 | Card padding, between rows |
| `Space.xl` | 24 | Between a heading and the card above it |
| `Space.xxl` | 36 | Between sections |

A page is one column, 600 points wide, centred when the window is wider.

## Shape

| Role | Points | Use it for |
|---|---|---|
| `Radius.small` | 6 | Rows, chips, small controls |
| `Radius.medium` | 10 | Cards and wells |
| `Radius.large` | 14 | Sheets and the largest panels |

Cards are a `raised` fill with a 1 point `line` border and no shadow. Depth
comes from the surface colours, not from shadows.

## Components

Layout pieces, in `Main/Theme.swift`:

- **`Page`**: a title, an optional subtitle, then content in the page column.
- **`Card`**: a `raised` panel with a `line` border.
- **`Keycap`**: a key as it looks on the keyboard.
- **`SidebarRow`**: a navigation row. Selected is an accent wash and an accent icon.

Controls and patterns, in `Main/KitControls.swift`:

- **`KitButtonStyle`**: primary, secondary, quiet and destructive, in two
  sizes. One primary per screen. A button with a destructive role looks
  destructive without being told.
- **`KitSwitchStyle`** and **`KitCheckboxStyle`**: a switch takes effect at
  once; a checkbox is one choice among several saved together.
- **`KitField`** and **`KitTextFieldStyle`**: a one-line text field.
- **`KitSegmented`**: up to about four options, all visible.
- **`KitMenu`** and **`KitPicker`**: one choice among many. The list that
  opens is the system's.
- **`KitProgress`**, **`KitTag`**: how far along, and a two-word state with
  an icon.
- **`KitForm`**, **`KitSection`**, **`KitRow`**: a settings page, a headed
  group of rows, and one row. Anything placed in a section becomes a row.
- **`KitHeader`**: a page's title with its actions on the right.

A window's root view calls `.skinned()`, which makes these the default for
every button, switch, text field and labelled value inside it.

Every piece and state is drawn on the gallery sheets in
`Main/KitGallery.swift`. Look there before building something new.

## Rules that keep it swappable

1. No hex values, and no `Color(nsColor:)`, outside `DesignKit.swift`.
2. No `Color.accentColor`. Use `Theme.accent`, which follows the skin.
3. No font sizes in views. Use a `Fonts` role, or add one to the kit.
4. A window's root view calls `.skinned()`, and its `NSWindow` uses
   `Theme.pageNSColor` as its background.
5. If a design needs a colour or size the kit doesn't have, add a role to the
   kit and document it here. Don't work around it in the view.

## Not converted yet

- Notes and Meetings still put their buttons in the macOS toolbar instead of
  a `KitHeader`.
- Pull-downs and steppers are the system's controls, tinted.
- Vocabulary and Snippets keep a few text fields and source tags drawn their
  own way, and status dots still use system green.
- The meeting window and onboarding are only partly converted.

## Outside the app

The emails the server sends and the website each carry their own copy of a
palette, and both still use the older `paper` look. They need updating by
hand to match Ink: `crates/fnspeak-server/src/mail.rs` for the emails, and
the site's stylesheet.
