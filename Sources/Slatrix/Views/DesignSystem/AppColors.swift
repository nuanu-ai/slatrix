import AppKit
import SwiftUI

extension AppearanceStore {
    var colors: AppColors { colors(for: activeWorkspaceID) }

    func colors(for workspaceID: String?) -> AppColors {
        AppColors(
            dark: isDark, accent: accent(dark: isDark), theme: effectiveTheme(for: workspaceID),
            highContrast: effectiveIncreaseContrast)
    }
}

/// Every color in the UI, by role. Views pick a role, never a value. A theme's neutral base and floating sidebar
/// surface, with one accent: the one picked in System Settings.
struct AppColors {
    private(set) var dark: Bool
    /// The system accent in this theme, in sRGB.
    private(set) var accentBase: NSColor
    let theme: ColorTheme
    let highContrast: Bool
    private var neutrals: Neutrals
    private var isSidebarContext = false

    init(dark: Bool, accent: NSColor? = nil, theme: ColorTheme = .glass, highContrast: Bool = false) {
        self.dark = dark
        accentBase = accent ?? Self.resolve(.controlAccentColor, dark: dark)
        self.theme = theme
        self.highContrast = highContrast
        neutrals = Neutrals(theme, dark: dark, highContrast: highContrast)
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
        /// A theme's floating sidebar surface when it diverges from the opaque neutral sidebar (glass or colored).
        var sidebarSurface: SidebarSurface?

        init(_ theme: ColorTheme, dark: Bool, highContrast: Bool) {
            switch (theme == .sand, dark, highContrast) {
            // Warm paper.
            case (true, false, false):
                (text, secondary, tertiary) = (0x231f1a, 0x60574c, 0x6e655a)
                (canvas, rowHover, raised, surfaceCard) = (0xfdfbf7, 0xf7f3eb, 0xf2ece2, 0xfffdfa)
                (sidebar, overlay, control, ink) = (0xf2ece2, 0xfffdfa, 0xffffff, 0x3c2814)
            case (true, false, true):
                (text, secondary, tertiary) = (0x000000, 0x3e372f, 0x574f45)
                (canvas, rowHover, raised, surfaceCard) = (0xfdfbf7, 0xf7f3eb, 0xf2ece2, 0xfffdfa)
                (sidebar, overlay, control, ink) = (0xf2ece2, 0xfffdfa, 0xffffff, 0x3c2814)
                lines = 2
            case (true, true, false):
                (text, secondary, tertiary) = (0xf2ede6, 0xaaa195, 0x9b9286)
                (canvas, rowHover, raised, surfaceCard) = (0x171512, 0x1f1c18, 0x27231e, 0x27231e)
                (sidebar, overlay, control, ink) = (0x221f1a, 0x2e2a24, 0x26221d, 0xfff0dc)
            case (true, true, true):
                (text, secondary, tertiary) = (0xffffff, 0xccc5bc, 0xb5ada2)
                (canvas, rowHover, raised, surfaceCard) = (0x050403, 0x13110e, 0x1e1a16, 0x1e1a16)
                (sidebar, overlay, control, ink) = (0x161310, 0x27231d, 0x181512, 0xfff0dc)
                lines = 2
            // Neutral graphite base shared by Glass, Neutral, Aubergine, Jade and Ocean.
            case (false, false, false):
                (text, secondary, tertiary) = (0x1d1d1f, 0x58585e, 0x6c6c72)
                (canvas, rowHover, raised, surfaceCard) = (0xffffff, 0xf6f6f8, 0xf2f2f5, 0xffffff)
                (sidebar, overlay, control, ink) = (0xf3f3f5, 0xfbfbfd, 0xffffff, 0x000000)
            case (false, false, true):
                (text, secondary, tertiary) = (0x000000, 0x3d3d42, 0x55555b)
                (canvas, rowHover, raised, surfaceCard) = (0xffffff, 0xf5f5f7, 0xf0f0f2, 0xffffff)
                (sidebar, overlay, control, ink) = (0xf0f0f2, 0xffffff, 0xffffff, 0x000000)
                lines = 2
            case (false, true, false):
                (text, secondary, tertiary) = (0xf5f5f7, 0x9e9ea5, 0x8e8e94)
                (canvas, rowHover, raised, surfaceCard) = (0x141416, 0x1b1b1f, 0x222227, 0x222227)
                (sidebar, overlay, control, ink) = (0x1d1d20, 0x27272d, 0x1f1f22, 0xffffff)
            case (false, true, true):
                (text, secondary, tertiary) = (0xffffff, 0xc7c7cc, 0xaeaeb2)
                (canvas, rowHover, raised, surfaceCard) = (0x000000, 0x101012, 0x19191d, 0x19191d)
                (sidebar, overlay, control, ink) = (0x141416, 0x222226, 0x161618, 0xffffff)
                lines = 2
            }
            if theme.isTranslucent || theme.isColored {
                sidebarSurface = SidebarSurface(theme, dark: dark, highContrast: highContrast)
            }
        }
    }

    /// A translucent glass or colored floating sidebar's fill, gradient end, and text contrast tuning.
    private struct SidebarSurface {
        /// The sidebar at the top, and where its built-in vertical gradient takes it by the bottom.
        var start, end, secondary, tertiary: UInt32
        /// Glass lets the desktop through the system's sidebar material under a tint that keeps text readable on any
        /// desktop.
        var opacity = 1.0
        var colored = true
        var translucent: Bool { opacity < 1 }

        init(_ theme: ColorTheme, dark: Bool, highContrast: Bool) {
            switch (theme, dark) {
            case (.aubergine, false):
                (start, end, secondary, tertiary) = (0x4a1f4f, 0x231b6f, 0xd4c9d5, 0xae99b1)
            case (.aubergine, true):
                (start, end, secondary, tertiary) = (0x2b1530, 0x0f1252, 0xc8c2c9, 0x958a98)
            case (.jade, false):
                (start, end, secondary, tertiary) = (0x1c4a3e, 0x17394f, 0xd6dedc, 0x9eb4ae)
            case (.jade, true):
                (start, end, secondary, tertiary) = (0x122e28, 0x081e3a, 0xc1c9c7, 0x889694)
            case (.ocean, false):
                (start, end, secondary, tertiary) = (0x1c3d61, 0x054040, 0xd6dce3, 0x9eb0c2)
            case (.ocean, true):
                (start, end, secondary, tertiary) = (0x13263c, 0x003b33, 0xc2c7cc, 0x9aa4b0)
            case (_, false):
                colored = false
                if highContrast {
                    (start, end, secondary, tertiary, opacity) = (0xf0f0f2, 0xf0f0f2, 0x3d3d42, 0x55555b, 0.94)
                } else {
                    (start, end, secondary, tertiary, opacity) = (0xf3f3f5, 0xf3f3f5, 0x46464b, 0x58585d, 0.85)
                }
            case (_, true):
                colored = false
                if highContrast {
                    (start, end, secondary, tertiary, opacity) = (0x141416, 0x141416, 0xc7c7cc, 0xaeaeb2, 0.94)
                } else {
                    (start, end, secondary, tertiary, opacity) = (0x1d1d20, 0x1d1d20, 0xc4c4ca, 0xa8a8ae, 0.88)
                }
            }
            if colored && highContrast {
                secondary = AppColors.mix(0xffffff, 0.45, over: secondary)
                tertiary = AppColors.mix(0xffffff, 0.45, over: tertiary)
            }
        }
    }
    private var ink: Color { Color(hex: neutrals.ink) }

    // MARK: Floating Sidebar & Wallpaper

    /// The floating sidebar panel's fill (or top stop for colored themes).
    var sidebar: Color {
        neutrals.sidebarSurface.map { Color(hex: $0.start).opacity($0.opacity) } ?? Color(hex: neutrals.sidebar)
    }
    /// Bottom stop of a colored floating sidebar's built-in gradient; equals `sidebar` on neutral themes.
    var sidebarEnd: Color {
        neutrals.sidebarSurface.map { Color(hex: $0.end).opacity($0.opacity) } ?? Color(hex: neutrals.sidebar)
    }
    /// Glass: the desktop shows through the floating sidebar panel.
    var translucentSidebar: Bool { neutrals.sidebarSurface?.translucent == true }
    /// Aubergine, Jade, Ocean: a dark colored floating sidebar island with light text.
    var coloredSidebar: Bool { neutrals.sidebarSurface?.colored == true }
    /// Faint repeating doodles behind messages when Chat wallpaper is enabled: subtle theme-tinted ink in light mode
    /// and soft white in dark mode.
    var wallpaperDoodle: Color {
        if dark { return .white.opacity(0.025) }
        if let surface = neutrals.sidebarSurface, surface.colored {
            return Color(hex: surface.start).opacity(0.025)
        }
        return Color(hex: neutrals.ink).opacity(0.025)
    }
    /// The colors of what sits inside the floating sidebar: deeper text over translucent glass, and crisp light text
    /// with a white accent over colored sidebar islands.
    var onSidebar: AppColors {
        var colors = self
        colors.isSidebarContext = true
        guard let surface = neutrals.sidebarSurface else { return colors }
        (colors.neutrals.secondary, colors.neutrals.tertiary) = (surface.secondary, surface.tertiary)
        guard surface.colored else {
            if surface.translucent && !dark {
                colors.accentBase = accentBase.blended(withFraction: 0.25, of: .black) ?? accentBase
            }
            return colors
        }
        colors.dark = true
        colors.accentBase = .white
        colors.neutrals.text = 0xffffff
        colors.neutrals.ink = 0xffffff
        colors.neutrals.canvas = surface.start
        colors.neutrals.rowHover = Self.mix(0xffffff, 0.08, over: surface.start)
        colors.neutrals.control = Self.mix(0xffffff, 0.12, over: surface.start)
        colors.neutrals.raised = Self.mix(0xffffff, 0.15, over: surface.start)
        colors.neutrals.surfaceCard = colors.neutrals.raised
        colors.neutrals.overlay = Self.mix(0xffffff, 0.2, over: surface.start)
        colors.neutrals.onAccent = surface.start
        colors.neutrals.lines = highContrast ? 2.0 : 1.6
        return colors
    }

    private static func mix(_ top: UInt32, _ amount: Double, over bottom: UInt32) -> UInt32 {
        [16, 8, 0].reduce(0) { mixed, shift in
            let (a, b) = (Double(top >> shift & 255), Double(bottom >> shift & 255))
            return mixed | UInt32((a * amount + b * (1 - amount)).rounded()) << shift
        }
    }

    private static func nsColor(hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    private static func composite(_ top: NSColor, over bottom: NSColor) -> NSColor {
        let top = top.usingColorSpace(.sRGB) ?? top
        let bottom = bottom.usingColorSpace(.sRGB) ?? bottom
        let a = top.alphaComponent
        return NSColor(
            srgbRed: top.redComponent * a + bottom.redComponent * (1 - a),
            green: top.greenComponent * a + bottom.greenComponent * (1 - a),
            blue: top.blueComponent * a + bottom.blueComponent * (1 - a), alpha: 1)
    }

    private static func relativeLuminance(_ color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722
            * linear(rgb.blueComponent)
    }

    private static func contrastRatio(_ first: NSColor, _ second: NSColor) -> Double {
        let l1 = relativeLuminance(first)
        let l2 = relativeLuminance(second)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// Leaves `candidate` untouched when it already clears `minimum` contrast against `background`, and otherwise
    /// steps minimally toward `target` so bright macOS accents (such as Yellow) remain WCAG AA legible.
    private static func ensuringContrast(
        _ candidate: NSColor, against background: NSColor, toward target: NSColor, minimum: Double = 4.5
    ) -> NSColor {
        let base = candidate.usingColorSpace(.sRGB) ?? candidate
        let bg = background.usingColorSpace(.sRGB) ?? background
        if contrastRatio(base, bg) >= minimum { return base }
        var low: CGFloat = 0
        var high: CGFloat = 1
        for _ in 0..<14 {
            let mid = (low + high) / 2
            let stepped = base.blended(withFraction: mid, of: target) ?? target
            if contrastRatio(stepped, bg) >= minimum { high = mid } else { low = mid }
        }
        return base.blended(withFraction: high, of: target) ?? target
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
    /// The keyboard focus ring around buttons, rows and fields: the system's in normal mode, or a contrast-checked
    /// ring on colored sidebars and under Increase contrast so keyboard focus never fades into the surface.
    static var focusRing: Color { Color(nsColor: .keyboardFocusIndicatorColor) }
    var focusRing: Color {
        if isSidebarContext && coloredSidebar { return .white }
        if highContrast { return accent }
        let surface = Self.nsColor(hex: isSidebarContext ? neutrals.sidebar : neutrals.canvas)
        let resolved = Self.resolve(.keyboardFocusIndicatorColor, dark: dark)
        if Self.contrastRatio(Self.composite(resolved, over: surface), surface) >= 3.0 {
            return Self.focusRing
        }
        return accent
    }

    // MARK: Accent and status

    /// The system accent as a fill: the one main button, the send button, badges, the highlighted menu row. Deepened
    /// under white text so filled buttons meet WCAG AA contrast for every macOS accent color, including Yellow.
    var accentFill: Color { Color(nsColor: resolvedAccentFill) }
    private var resolvedAccentFill: NSColor {
        guard neutrals.onAccent == 0xffffff else { return accentBase }
        let stepped = accentBase.blended(withFraction: dark ? 0.24 : 0.16, of: .black) ?? accentBase
        return Self.ensuringContrast(stepped, against: Self.nsColor(hex: neutrals.onAccent), toward: .black)
    }
    /// The accent as text and icons: links, the open conversation's icon, a mention. Deepened in light mode so links
    /// stay readable over chat wallpaper doodles, and lifted in dark mode so it reads as text on the canvas.
    var accent: Color {
        if isSidebarContext && coloredSidebar { return .white }
        let depth: CGFloat = dark ? (highContrast ? 0.3 : 0.2) : (highContrast ? 0.4 : 0.3)
        let stepped = accentBase.blended(withFraction: depth, of: dark ? .white : .black) ?? accentBase
        let background: NSColor
        if isSidebarContext, let surface = neutrals.sidebarSurface, surface.translucent {
            let tint = Self.nsColor(hex: surface.start, alpha: surface.opacity)
            background = Self.composite(tint, over: dark ? .white : .black)
        } else if isSidebarContext {
            background = Self.nsColor(hex: neutrals.sidebar)
        } else {
            let canvasColor = Self.nsColor(hex: neutrals.canvas)
            let doodleColor =
                dark
                ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.025)
                : Self.nsColor(
                    hex: neutrals.sidebarSurface?.colored == true ? neutrals.sidebarSurface!.start : neutrals.ink,
                    alpha: 0.025)
            background = Self.composite(doodleColor, over: canvasColor)
        }
        return Color(
            nsColor: Self.ensuringContrast(stepped, against: background, toward: dark ? .white : .black))
    }
    /// The fill behind something of yours, such as your reaction or a mention of you.
    var accentTint: Color { accentFill.opacity(dark ? 0.18 : 0.1) }
    /// The edge of something of yours.
    var accentLine: Color { accentFill.opacity(dark ? 0.5 : 0.32) }
    /// Text and icons on an accent fill.
    var onAccent: Color { Color(hex: neutrals.onAccent) }
    /// Done and verified marks.
    var success: Color {
        Color(hex: dark ? (highContrast ? 0x4ae06d : 0x30d158) : (highContrast ? 0x146326 : 0x1e7a34))
    }
    /// Destructive text, icons and inline errors, bright enough to read on dark canvas, overlay, and selected colored
    /// sidebar rows.
    var destructive: Color {
        let baseHex: UInt32 = dark ? (highContrast ? 0xff8078 : 0xff6961) : (highContrast ? 0xb50012 : 0xd70015)
        guard isSidebarContext, let surface = neutrals.sidebarSurface, surface.colored else {
            return Color(hex: baseHex)
        }
        let selectionAlpha = 0.1 * neutrals.lines
        let selStart = Self.composite(
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: selectionAlpha), over: Self.nsColor(hex: surface.start))
        let selEnd = Self.composite(
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: selectionAlpha), over: Self.nsColor(hex: surface.end))
        let adjustedStart = Self.ensuringContrast(Self.nsColor(hex: baseHex), against: selStart, toward: .white)
        let adjusted = Self.ensuringContrast(adjustedStart, against: selEnd, toward: .white)
        return Color(nsColor: adjusted)
    }
    /// Destructive button fill under white `onAccent` text.
    var destructiveFill: Color {
        Color(hex: dark ? 0xde2c2c : (highContrast ? 0xb50012 : 0xd70015))
    }
    /// Connection trouble and recoverable failures.
    var warning: Color {
        Color(hex: dark ? (highContrast ? 0xffb340 : 0xff9f0a) : (highContrast ? 0x7d3f00 : 0x9a4f00))
    }
    /// An @Name pill in a message or the composer. Deeper than the accent in light mode, so it reads on its tint.
    var mentionText: Color {
        if dark { return accent }
        let pill = Self.composite(
            resolvedAccentFill.withAlphaComponent(0.1), over: Self.nsColor(hex: neutrals.canvas))
        let stepped = accentBase.blended(withFraction: 0.5, of: .black) ?? accentBase
        return Color(nsColor: Self.ensuringContrast(stepped, against: pill, toward: .black))
    }
    var mentionFill: Color { accentTint }
    /// The pill of a mention that notifies you, or everyone: warm amber so it stands apart from links and other
    /// mentions, matching Slack desktop and Slatrix Android.
    var mentionYouText: Color { Color(hex: dark ? 0xffe58f : (highContrast ? 0x5c3900 : 0x7a4d00)) }
    var mentionYouFill: Color { Color(hex: dark ? 0xcc8e14 : 0xf2c744).opacity(dark ? 0.22 : 0.3) }
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

private struct OnSidebarKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set on what sits inside the floating sidebar panel so it draws in `AppColors.onSidebar`.
    var onSidebar: Bool {
        get { self[OnSidebarKey.self] }
        set { self[OnSidebarKey.self] = newValue }
    }
}

/// The theme's colors where a view sits: on the window canvas, or inside the floating sidebar panel.
@MainActor @propertyWrapper struct ThemeColors: DynamicProperty {
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(\.onSidebar) private var onSidebar
    var wrappedValue: AppColors { onSidebar ? appearance.colors.onSidebar : appearance.colors }
}
