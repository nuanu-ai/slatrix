import AppKit
import SwiftUI

extension AppearanceStore {
    var colors: AppColors { AppColors(dark: isDark, accent: accent(dark: isDark)) }
}

/// Every color in the UI, by role. Views pick a role, never a value. A neutral base and one accent, the one picked in
/// System Settings.
struct AppColors {
    let dark: Bool
    /// The system accent in this theme, in sRGB.
    let accentBase: NSColor

    init(dark: Bool, accent: NSColor? = nil) {
        self.dark = dark
        accentBase = accent ?? Self.resolve(.controlAccentColor, dark: dark)
    }

    /// A dynamic system color as it draws in one theme.
    static func resolve(_ color: NSColor, dark: Bool) -> NSColor {
        var resolved = color
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    // MARK: Text

    /// Names, titles and headings.
    var textPrimary: Color { Color(hex: dark ? 0xf5f5f7 : 0x1d1d1f) }
    /// Message bodies and running text.
    var textBody: Color { textPrimary }
    /// Times, descriptions, section titles, secondary lines.
    var textSecondary: Color { Color(hex: dark ? 0x98989f : 0x6a6a6f) }
    /// Icons at rest, placeholders, disabled text and hints.
    var textTertiary: Color { Color(hex: dark ? 0x8e8e94 : 0x86868b) }

    // MARK: Surfaces

    /// The window: the conversation, panes and modals. Near black in dark mode, as Apple's own apps are.
    var canvas: Color { Color(hex: dark ? 0x141416 : 0xffffff) }
    /// Cards and tiles that sit on the canvas, in the sidebar's gray.
    var raised: Color { sidebar }
    /// Wells: reserved media boxes, chips, skeletons, filled round buttons.
    var sunken: Color { dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05) }
    /// Menus, popovers, the switcher and toasts that float over content.
    var overlay: Color { Color(hex: dark ? 0x252528 : 0xfbfbfd) }
    /// The toolbar's capsules and the composer, which sit a hair above the canvas.
    var control: Color { Color(hex: dark ? 0x1f1f22 : 0xffffff) }
    /// Tooltips: a dark bubble in light mode, and in dark mode a step lighter than every surface.
    var tooltip: Color { Color(hex: dark ? 0x2e2e32 : 0x1d1d1f) }
    var onTooltip: Color { Color(hex: 0xffffff) }
    /// Dims the window under a modal.
    var scrim: Color { Color.black.opacity(dark ? 0.48 : 0.32) }
    /// The sidebar, a panel inset in the window.
    var sidebar: Color { Color(hex: dark ? 0x1d1d20 : 0xf3f3f5) }

    // MARK: Lines

    /// Dividers and the hairlines of cards.
    var border: Color { dark ? Color.white.opacity(0.1) : Color.black.opacity(0.09) }
    /// Fields, checkboxes and secondary buttons.
    var borderStrong: Color { dark ? Color.white.opacity(0.16) : Color.black.opacity(0.15) }

    // MARK: Interaction

    var hover: Color { dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05) }
    var pressed: Color { dark ? Color.white.opacity(0.12) : Color.black.opacity(0.09) }
    /// What is picked in a list: the open conversation in the sidebar, a search result, a Preferences tab.
    var selection: Color { dark ? Color.white.opacity(0.1) : Color.black.opacity(0.07) }
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
    /// The pill of a mention that notifies you, or everyone.
    var mentionYouText: Color { accent }
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
