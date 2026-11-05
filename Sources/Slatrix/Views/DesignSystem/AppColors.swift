import AppKit
import SwiftUI

extension AppearanceStore {
    var colors: AppColors { AppColors(dark: isDark, accent: accent(dark: isDark), theme: theme) }
}

/// Every color in the UI, by role. Views pick a role, never a value. A theme's neutral base and one accent, the one
/// picked in System Settings.
struct AppColors {
    let dark: Bool
    /// The system accent in this theme, in sRGB.
    let accentBase: NSColor
    let theme: ColorTheme
    private let neutrals: Neutrals

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
        var text, secondary, tertiary, canvas, sidebar, overlay, control: UInt32
        var ink: UInt32
        /// How much stronger lines and the selection are than the default theme's.
        var lines = 1.0

        init(_ theme: ColorTheme, dark: Bool) {
            switch (theme, dark) {
            case (.standard, false):
                (text, secondary, tertiary) = (0x1d1d1f, 0x636368, 0x86868b)
                (canvas, sidebar, overlay, control, ink) = (0xffffff, 0xf3f3f5, 0xfbfbfd, 0xffffff, 0x000000)
            case (.standard, true):
                (text, secondary, tertiary) = (0xf5f5f7, 0x9e9ea5, 0x8e8e94)
                (canvas, sidebar, overlay, control, ink) = (0x141416, 0x1d1d20, 0x252528, 0x1f1f22, 0xffffff)
            // Cool blue-gray, like a slate.
            case (.slate, false):
                (text, secondary, tertiary) = (0x111827, 0x556070, 0x667085)
                (canvas, sidebar, overlay, control, ink) = (0xffffff, 0xeef1f7, 0xfafbfd, 0xffffff, 0x101828)
            case (.slate, true):
                (text, secondary, tertiary) = (0xe8ecf4, 0x9aa3b5, 0x8b94a7)
                (canvas, sidebar, overlay, control, ink) = (0x0d1017, 0x151a26, 0x1e2536, 0x1a2030, 0xffffff)
            // Warm paper.
            case (.sand, false):
                (text, secondary, tertiary) = (0x231f1a, 0x655c51, 0x756c61)
                (canvas, sidebar, overlay, control, ink) = (0xfdfbf7, 0xf2ece2, 0xfffdfa, 0xffffff, 0x3c2814)
            case (.sand, true):
                (text, secondary, tertiary) = (0xf2ede6, 0xaaa195, 0x9b9286)
                (canvas, sidebar, overlay, control, ink) = (0x171512, 0x221f1a, 0x2a2620, 0x26221d, 0xfff0dc)
            // Black and white text, and lines twice as strong.
            case (.contrast, false):
                (text, secondary, tertiary) = (0x000000, 0x3d3d42, 0x55555b)
                (canvas, sidebar, overlay, control, ink) = (0xffffff, 0xf0f0f2, 0xffffff, 0xffffff, 0x000000)
                lines = 2
            case (.contrast, true):
                (text, secondary, tertiary) = (0xffffff, 0xc7c7cc, 0xaeaeb2)
                (canvas, sidebar, overlay, control, ink) = (0x000000, 0x141416, 0x1c1c1f, 0x161618, 0xffffff)
                lines = 2
            }
        }
    }
    private var ink: Color { Color(hex: neutrals.ink) }

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
    /// Cards and tiles that sit on the canvas, in the sidebar's gray.
    var raised: Color { sidebar }
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

    /// The system accent as a fill: the one main button, the send button, badges, the highlighted menu row.
    var accentFill: Color { Color(nsColor: accentBase) }
    /// The accent as text and icons: links, the open conversation's icon, a mention. Deepened in light mode and lifted
    /// in dark mode, so it reads as text on the canvas.
    var accent: Color {
        Color(nsColor: accentBase.blended(withFraction: 0.2, of: dark ? .white : .black) ?? accentBase)
    }
    /// The fill behind something of yours, such as your reaction or a mention of you.
    var accentTint: Color { accentFill.opacity(dark ? 0.18 : 0.1) }
    /// The edge of something of yours.
    var accentLine: Color { accentFill.opacity(dark ? 0.5 : 0.32) }
    /// Text and icons on an accent fill.
    var onAccent: Color { .white }
    /// Done and verified marks.
    var success: Color { Color(hex: dark ? 0x30d158 : 0x248a3d) }
    var destructive: Color { Color(hex: dark ? 0xff453a : 0xd70015) }
    /// Connection trouble and recoverable failures.
    var warning: Color { Color(hex: dark ? 0xff9f0a : 0xc46800) }
    /// An @Name pill in a message or the composer.
    var mentionText: Color { accent }
    var mentionFill: Color { .clear }
    /// The pill of a mention that notifies you, or everyone. Deeper than the accent in light mode, so it reads on its
    /// tint.
    var mentionYouText: Color {
        dark ? accent : Color(nsColor: accentBase.blended(withFraction: 0.35, of: .black) ?? accentBase)
    }
    var mentionYouFill: Color { accentTint }
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
    /// A file card's type tile, under a white glyph in either theme.
    func file(_ kind: FileKind) -> Color {
        switch kind {
        case .pdf: Color(hex: 0xd93a3a)
        case .document: Color(hex: 0x2f6fde)
        case .spreadsheet: Color(hex: 0x1f8f55)
        case .presentation: Color(hex: 0xe8771e)
        case .archive: Color(hex: 0x7d8086)
        case .code: Color(hex: 0x5b55c9)
        case .audio: Color(hex: 0xc23d84)
        case .video: Color(hex: 0x8a4fd1)
        case .image: Color(hex: 0x1b93a8)
        case .generic: Color(hex: 0x5c6878)
        }
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
    let parts = value.trimmingCharacters(in: CharacterSet(charactersIn: "@#!")).split(whereSeparator: {
        $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-"
    })
    return parts.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
}

func avatarColor(_ name: String) -> Color {
    let hash = name.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
    return Color(hex: [0x78669d, 0x447389, 0x9a6d4c, 0x5d7f5a, 0xa16576, 0x5d78a0][Int(hash % 6)])
}
