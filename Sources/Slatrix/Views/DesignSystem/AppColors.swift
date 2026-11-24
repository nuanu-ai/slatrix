import AppKit
import SwiftUI

extension AppearanceStore {
    var colors: AppColors { AppColors(dark: isDark, accent: accent(dark: isDark), theme: theme) }
}

/// Every color in the UI, by role. Views pick a role, never a value. A theme's neutral base and one accent, the one
/// picked in System Settings.
struct AppColors {
    private(set) var dark: Bool
    /// The system accent in this theme, in sRGB.
    private(set) var accentBase: NSColor
    let theme: ColorTheme
    private var neutrals: Neutrals

    init(dark: Bool, accent: NSColor? = nil, theme: ColorTheme = .standard) {
        self.dark = dark
        accentBase = accent ?? Self.resolve(.controlAccentColor, dark: dark)
        self.theme = theme
        neutrals = Neutrals(theme, dark: dark)
    }

    /// A dynamic system color as it draws in one theme.
    static func resolve(_ color: NSColor, dark: Bool) -> NSColor {
        var resolved = color
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    /// What a theme changes: its surfaces, its text, and the ink its lines, wells and hovers are drawn in.
    private struct Neutrals {
        var text, secondary, tertiary, canvas, rowHover, raised, surfaceCard, sidebar, overlay, control: UInt32
        var ink: UInt32
        /// How much stronger lines and the selection are than the default theme's.
        var lines = 1.0
        var onAccent: UInt32 = 0xffffff
        /// A frame theme's window frame; the others leave the canvas there.
        var frame: Frame?

        init(_ theme: ColorTheme, dark: Bool) {
            if theme.framed {
                self = Neutrals(.standard, dark: dark)
                frame = Frame(theme, dark: dark)
                return
            }
            switch (theme, dark) {
            case (.standard, false):
                (text, secondary, tertiary) = (0x1d1d1f, 0x58585e, 0x6c6c72)
                (canvas, rowHover, raised, surfaceCard) = (0xffffff, 0xf6f6f8, 0xf2f2f5, 0xffffff)
                (sidebar, overlay, control, ink) = (0xf3f3f5, 0xfbfbfd, 0xffffff, 0x000000)
            case (.standard, true):
                (text, secondary, tertiary) = (0xf5f5f7, 0x9e9ea5, 0x8e8e94)
                (canvas, rowHover, raised, surfaceCard) = (0x141416, 0x1b1b1f, 0x222227, 0x222227)
                (sidebar, overlay, control, ink) = (0x1d1d20, 0x27272d, 0x1f1f22, 0xffffff)
            // Cool blue-gray, like a slate.
            case (.slate, false):
                (text, secondary, tertiary) = (0x111827, 0x556070, 0x616b7f)
                (canvas, rowHover, raised, surfaceCard) = (0xffffff, 0xf4f6fa, 0xeef1f7, 0xffffff)
                (sidebar, overlay, control, ink) = (0xeef1f7, 0xfafbfd, 0xffffff, 0x101828)
            case (.slate, true):
                (text, secondary, tertiary) = (0xe8ecf4, 0x9aa3b5, 0x8b94a7)
                (canvas, rowHover, raised, surfaceCard) = (0x0d1017, 0x131823, 0x1b2231, 0x1b2231)
                (sidebar, overlay, control, ink) = (0x151a26, 0x222a3c, 0x1a2030, 0xffffff)
            // Warm paper.
            case (.sand, false):
                (text, secondary, tertiary) = (0x231f1a, 0x60574c, 0x6e655a)
                (canvas, rowHover, raised, surfaceCard) = (0xfdfbf7, 0xf7f3eb, 0xf2ece2, 0xfffdfa)
                (sidebar, overlay, control, ink) = (0xf2ece2, 0xfffdfa, 0xffffff, 0x3c2814)
            case (.sand, true):
                (text, secondary, tertiary) = (0xf2ede6, 0xaaa195, 0x9b9286)
                (canvas, rowHover, raised, surfaceCard) = (0x171512, 0x1f1c18, 0x27231e, 0x27231e)
                (sidebar, overlay, control, ink) = (0x221f1a, 0x2e2a24, 0x26221d, 0xfff0dc)
            // Black and white text, and lines twice as strong.
            case (.contrast, false):
                (text, secondary, tertiary) = (0x000000, 0x3d3d42, 0x55555b)
                (canvas, rowHover, raised, surfaceCard) = (0xffffff, 0xf5f5f7, 0xf0f0f2, 0xffffff)
                (sidebar, overlay, control, ink) = (0xf0f0f2, 0xffffff, 0xffffff, 0x000000)
                lines = 2
            case (.contrast, true):
                (text, secondary, tertiary) = (0xffffff, 0xc7c7cc, 0xaeaeb2)
                (canvas, rowHover, raised, surfaceCard) = (0x000000, 0x101012, 0x19191d, 0x19191d)
                (sidebar, overlay, control, ink) = (0x141416, 0x222226, 0x161618, 0xffffff)
                lines = 2
            default: preconditionFailure("\(theme) draws a frame")
            }
        }
    }

    /// A frame theme's frame and the sidebar's text on it, light on the colored ones.
    private struct Frame {
        /// The frame at the top, and where the window gradient takes it by the bottom.
        var start, end, secondary, tertiary: UInt32
        /// Glass lets the desktop through the system's sidebar material, under a tint that keeps text readable on any
        /// desktop.
        var opacity = 1.0
        var translucent: Bool { opacity < 1 }

        init(_ theme: ColorTheme, dark: Bool) {
            switch (theme, dark) {
            case (.aubergine, false): (start, end, secondary, tertiary) = (0x4a1f4f, 0x231b6f, 0xd4c9d5, 0xae99b1)
            case (.aubergine, true): (start, end, secondary, tertiary) = (0x2b1530, 0x0f1252, 0xc8c2c9, 0x958a98)
            case (.jade, false): (start, end, secondary, tertiary) = (0x1c4a3e, 0x17394f, 0xd6dedc, 0x9eb4ae)
            case (.jade, true): (start, end, secondary, tertiary) = (0x122e28, 0x081e3a, 0xc1c9c7, 0x889694)
            case (.lagoon, false): (start, end, secondary, tertiary) = (0x1c3d61, 0x054040, 0xd6dce3, 0x9eb0c2)
            case (.lagoon, true): (start, end, secondary, tertiary) = (0x13263c, 0x003b33, 0xc2c7cc, 0x9aa4b0)
            case (.midnight, false): (start, end, secondary, tertiary) = (0x141c3a, 0x401656, 0xc2c4cc, 0x989caa)
            case (.midnight, true): (start, end, secondary, tertiary) = (0x0c1126, 0x2d083f, 0xc0c1c7, 0x868892)
            case (_, false): (start, end, secondary, tertiary, opacity) = (0xf3f3f5, 0xf3f3f5, 0x46464b, 0x58585d, 0.85)
            case (_, true): (start, end, secondary, tertiary, opacity) = (0x1d1d20, 0x1d1d20, 0xc4c4ca, 0xa8a8ae, 0.88)
            }
        }
    }
    private var ink: Color { Color(hex: neutrals.ink) }

    // MARK: Frame

    /// The window around the sidebar and the conversation: the canvas, unless the theme colors it.
    var frame: Color { neutrals.frame.map { Color(hex: $0.start).opacity($0.opacity) } ?? canvas }
    /// Where the window gradient takes the frame, at the bottom.
    var frameEnd: Color { neutrals.frame.map { Color(hex: $0.end).opacity($0.opacity) } ?? canvas }
    /// Glass: the desktop shows through the frame.
    var translucentFrame: Bool { neutrals.frame?.translucent == true }
    /// The doodles behind the messages in a frame theme: a texture under the text, faint enough that it reads as the
    /// theme's and never as marks among the words.
    var wallpaperDoodle: Color {
        guard let frame = neutrals.frame else { return .clear }
        if dark { return .white.opacity(0.025) }
        return frame.translucent ? .black.opacity(0.025) : Color(hex: frame.start).opacity(0.025)
    }
    /// The colors of what sits on the frame, such as the sidebar: on a colored frame its text, lines and fills are
    /// light, and the accent is white, as in Slack's sidebar.
    var onFrame: AppColors {
        guard let frame = neutrals.frame else { return self }
        var colors = self
        (colors.neutrals.secondary, colors.neutrals.tertiary) = (frame.secondary, frame.tertiary)
        guard !frame.translucent else { return colors }
        colors.dark = true
        colors.accentBase = .white
        colors.neutrals.text = 0xffffff
        colors.neutrals.ink = 0xffffff
        (colors.neutrals.canvas, colors.neutrals.sidebar) = (frame.start, frame.start)
        colors.neutrals.rowHover = Self.mix(0xffffff, 0.08, over: frame.start)
        colors.neutrals.raised = Self.mix(0xffffff, 0.12, over: frame.start)
        colors.neutrals.surfaceCard = colors.neutrals.raised
        colors.neutrals.control = Self.mix(0xffffff, 0.12, over: frame.start)
        colors.neutrals.onAccent = frame.start
        colors.neutrals.lines = 1.6
        return colors
    }

    private static func mix(_ top: UInt32, _ amount: Double, over bottom: UInt32) -> UInt32 {
        [16, 8, 0].reduce(0) { mixed, shift in
            let (a, b) = (Double(top >> shift & 255), Double(bottom >> shift & 255))
            return mixed | UInt32((a * amount + b * (1 - amount)).rounded()) << shift
        }
    }

    // MARK: Text

    /// Names, titles and headings.
    var textPrimary: Color { Color(hex: neutrals.text) }
    /// Message bodies and running text.
    var textBody: Color { textPrimary }
    /// Times, descriptions, section titles, secondary lines.
    var textSecondary: Color { Color(hex: neutrals.secondary) }
    /// Icons at rest, placeholders, disabled text and hints.
    var textTertiary: Color { Color(hex: neutrals.tertiary) }

    // MARK: Surfaces

    /// The window: the conversation, panes and modals. Near black in dark mode, as Apple's own apps are.
    var canvas: Color { Color(hex: neutrals.canvas) }
    /// Opaque hover band for message and list rows, keeping wallpaper doodles from bleeding through.
    var rowHover: Color { Color(hex: neutrals.rowHover) }
    /// Grouped cards, secondary panels and footers that sit on the canvas.
    var raised: Color { Color(hex: neutrals.raised) }
    /// Interactive cards (files, attachments) lifted above hovered rows in both light and dark modes.
    var surfaceCard: Color { Color(hex: neutrals.surfaceCard) }
    /// Wells: reserved media boxes, chips, skeletons, filled round buttons.
    var sunken: Color { ink.opacity(dark ? 0.07 : 0.05) }
    /// Menus, popovers, the switcher and toasts that float over content.
    var overlay: Color { Color(hex: neutrals.overlay) }
    /// The toolbar's capsules and the composer, which sit a hair above the canvas.
    var control: Color { Color(hex: neutrals.control) }
    /// Tooltips: a dark bubble in both themes, darker than the conversation in dark mode.
    var tooltip: Color { Color(hex: dark ? 0x0b0b0c : 0x1d1d1f) }
    var onTooltip: Color { Color(hex: 0xffffff) }
    /// Dims the window under a modal.
    var scrim: Color { Color.black.opacity(dark ? 0.48 : 0.32) }
    /// The sidebar, a panel inset in the window.
    var sidebar: Color { Color(hex: neutrals.sidebar) }

    // MARK: Lines

    /// Dividers and the hairlines of cards.
    var border: Color { ink.opacity((dark ? 0.1 : 0.09) * neutrals.lines) }
    /// Fields, checkboxes and secondary buttons.
    var borderStrong: Color { ink.opacity((dark ? 0.16 : 0.15) * neutrals.lines) }

    // MARK: Interaction

    var hover: Color { ink.opacity(dark ? 0.07 : 0.05) }
    var pressed: Color { ink.opacity(dark ? 0.12 : 0.09) }
    /// What is picked in a list: the open conversation in the sidebar, a search result, a Preferences tab.
    var selection: Color { ink.opacity((dark ? 0.1 : 0.07) * neutrals.lines) }
    /// Words a search matched, in a result.
    var highlight: Color { Color(hex: 0xffcc00).opacity(dark ? 0.3 : 0.4) }
    /// The keyboard focus ring around buttons, rows and fields: the system's, in the accent.
    static var focusRing: Color { Color(nsColor: .keyboardFocusIndicatorColor) }
    var focusRing: Color { Self.focusRing }

    // MARK: Accent and status

    /// The system accent as a fill: the one main button, the send button, badges, the highlighted menu row. Deepened
    /// slightly under white text so filled buttons meet WCAG AA contrast.
    var accentFill: Color {
        guard neutrals.onAccent == 0xffffff else { return Color(nsColor: accentBase) }
        return Color(nsColor: accentBase.blended(withFraction: dark ? 0.24 : 0.16, of: .black) ?? accentBase)
    }
    /// The accent as text and icons: links, the open conversation's icon, a mention. Deepened in light mode, more so
    /// over a frame theme's doodles, and lifted in dark mode, so it reads as text on the canvas.
    var accent: Color {
        let depth = dark || neutrals.frame == nil ? 0.2 : 0.3
        return Color(nsColor: accentBase.blended(withFraction: depth, of: dark ? .white : .black) ?? accentBase)
    }
    /// The fill behind something of yours, such as your reaction or a mention of you.
    var accentTint: Color { accentFill.opacity(dark ? 0.18 : 0.1) }
    /// The edge of something of yours.
    var accentLine: Color { accentFill.opacity(dark ? 0.5 : 0.32) }
    /// Text and icons on an accent fill.
    var onAccent: Color { Color(hex: neutrals.onAccent) }
    /// Done and verified marks.
    var success: Color { Color(hex: dark ? 0x30d158 : 0x1e7a34) }
    /// Destructive text, icons and inline errors, bright enough to read on dark canvas and overlay surfaces.
    var destructive: Color { Color(hex: dark ? 0xff6961 : 0xd70015) }
    /// Destructive button fill under white `onAccent` text.
    var destructiveFill: Color { Color(hex: dark ? 0xde2c2c : 0xd70015) }
    /// Connection trouble and recoverable failures.
    var warning: Color { Color(hex: dark ? 0xff9f0a : 0x9a4f00) }
    /// An @Name pill in a message or the composer. Deeper than the accent in light mode, so it reads on its tint.
    var mentionText: Color { dark ? accent : deepAccent }
    var mentionFill: Color { accentTint }
    /// The pill of a mention that notifies you, or everyone: warm amber so it stands apart from links and other
    /// mentions, matching Slack desktop and Slatrix Android.
    var mentionYouText: Color { Color(hex: dark ? 0xffe58f : 0x7a4d00) }
    var mentionYouFill: Color { Color(hex: dark ? 0xcc8e14 : 0xf2c744).opacity(dark ? 0.22 : 0.3) }
    private var deepAccent: Color { Color(nsColor: accentBase.blended(withFraction: 0.5, of: .black) ?? accentBase) }
    /// Inline code in a message.
    var code: Color { sunken }
    var presenceActive: Color { Color(hex: dark ? 0x30d158 : 0x34c759) }
    var presenceAway: Color { textTertiary }

    // MARK: Media

    /// Behind the media viewer: near black in either theme, and opaque so nothing ghosts through.
    var mediaBackdrop: Color { Color(hex: 0x1a1b1e) }
    /// Chips over a photo or video: play, duration and the GIF tag.
    var mediaControl: Color { Color.black.opacity(0.6) }
    /// Over the part of a photo left out, such as outside the crop frame; half black in either theme.
    var mediaShade: Color { Color.black.opacity(0.5) }
    /// Text and icons over media and in the media viewer.
    var onMedia: Color { .white }
    /// A thin edge around white lines over a photo, such as the crop frame, so they still show against white.
    var onMediaEdge: Color { Color.black.opacity(0.4) }
    private static func fileHex(_ kind: FileKind) -> UInt32 {
        switch kind {
        case .pdf: 0xd93a3a
        case .document: 0x2f6fde
        case .spreadsheet: 0x1f8f55
        case .presentation: 0xe8771e
        case .archive: 0x7d8086
        case .code: 0x5b55c9
        case .audio: 0xc23d84
        case .video: 0x8a4fd1
        case .image: 0x1b93a8
        case .generic: 0x5c6878
        }
    }

    /// A file type's shared hue from `design/tokens.json`.
    func file(_ kind: FileKind) -> Color { Color(hex: Self.fileHex(kind)) }
    /// Soft tinted fill behind a file type symbol, avoiding saturated blocks that compete with links.
    func fileFill(_ kind: FileKind) -> Color { file(kind).opacity(dark ? 0.16 : 0.12) }
    /// Subtle tinted hairline around a file type tile.
    func fileEdge(_ kind: FileKind) -> Color { file(kind).opacity(dark ? 0.24 : 0.18) }
    /// Vector symbol tint inside a file type tile, lifted in dark mode and deepened in light mode for contrast.
    func fileGlyph(_ kind: FileKind) -> Color {
        Color(hex: Self.mix(dark ? 0xffffff : 0x000000, dark ? 0.28 : 0.16, over: Self.fileHex(kind)))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255, opacity: 1)
    }
}

func initials(_ value: String) -> String {
    let parts = value.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-" })
    return parts.compactMap { $0.first(where: isLetterOrDigit) }.prefix(2).map { String($0).uppercased() }.joined()
}

/// Unicode letters and decimal digits, as Android's `Character.isLetterOrDigit` reads them, so both apps agree; a keycap
/// such as 1️⃣ is a digit in an enclosing mark, a symbol.
private func isLetterOrDigit(_ character: Character) -> Bool {
    if character.unicodeScalars.contains(where: { $0.properties.generalCategory == .enclosingMark }) { return false }
    return switch character.unicodeScalars.first?.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: true
    default: false
    }
}

private let avatarColors: [UInt32] = [
    0x9c5f68, 0x9b624e, 0x90693b, 0x7b7137, 0x5f7845, 0x407c5e,
    0x267c78, 0x2e798f, 0x4b749d, 0x686ca0, 0x816596, 0x936082,
]

func avatarColor(_ name: String) -> Color {
    let hash = name.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
    return Color(hex: avatarColors[Int(hash % UInt64(avatarColors.count))])
}

private struct OnFrameKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set on what sits on a frame theme's frame, such as the sidebar, so it draws in `AppColors.onFrame`.
    var onFrame: Bool {
        get { self[OnFrameKey.self] }
        set { self[OnFrameKey.self] = newValue }
    }
}

/// The theme's colors where a view sits: on the window, or on a frame theme's frame.
@MainActor @propertyWrapper struct ThemeColors: DynamicProperty {
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(\.onFrame) private var onFrame
    var wrappedValue: AppColors { onFrame ? appearance.colors.onFrame : appearance.colors }
}
