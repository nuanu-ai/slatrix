import SwiftUI

extension AppearanceStore {
    var colors: AppColors { AppColors(dark: isDark, palette: palette) }
}

/// Every color in the UI, by role. Views pick a role, never a value.
struct AppColors {
    let dark: Bool
    let palette: SidebarPalette

    // MARK: Text

    /// Names, titles and headings.
    var textPrimary: Color { Color(hex: dark ? 0xf5f5f5 : 0x1d1c1d) }
    /// Message bodies and running text.
    var textBody: Color { Color(hex: dark ? 0xd1d2d3 : 0x1d1c1d) }
    /// Timestamps, descriptions, secondary lines.
    var textSecondary: Color { Color(hex: dark ? 0xabadb1 : 0x616061) }
    /// Placeholders, disabled text and hints.
    var textTertiary: Color { Color(hex: dark ? 0x7c7f84 : 0x8d8c8d) }

    // MARK: Surfaces

    /// The conversation and modal background.
    var canvas: Color { Color(hex: dark ? 0x1c1d21 : 0xffffff) }
    /// Cards and tiles that sit on the canvas.
    var raised: Color { Color(hex: dark ? 0x24262a : 0xf8f8f8) }
    /// Wells: reserved media boxes, chips, skeletons.
    var sunken: Color { Color(hex: dark ? 0x27282c : 0xf4f4f4) }
    /// Popovers, menus, toolbars and toasts that float over content.
    var overlay: Color { Color(hex: dark ? 0x222529 : 0xffffff) }
    /// Tooltips: a dark bubble in both themes, as Slack's are. In dark mode it sits below the canvas, and the
    /// elevation's hairline sets it apart from the conversation.
    var tooltip: Color { Color(hex: dark ? 0x111214 : 0x1d1c1d) }
    var onTooltip: Color { Color(hex: 0xffffff) }
    /// Dims the window under a modal.
    var scrim: Color { Color.black.opacity(dark ? 0.48 : 0.32) }
    var sidebar: Color {
        guard dark else { return Color(hex: 0xf8f8f8) }
        return switch palette {
        case .slate: Color(hex: 0x17181a)
        case .aubergine: Color(hex: 0x211323)
        case .ocean: Color(hex: 0x13212b)
        case .forest: Color(hex: 0x15231d)
        }
    }
    /// The window around the panels: title bar and rail.
    var frame: Color {
        guard dark else {
            return switch palette {
            case .slate: Color(hex: 0xf0f0f0)
            case .aubergine: Color(hex: 0xede4ef)
            case .ocean: Color(hex: 0xe2edf4)
            case .forest: Color(hex: 0xe4eee7)
            }
        }
        return switch palette {
        case .slate: Color(hex: 0x202124)
        case .aubergine: Color(hex: 0x350d36)
        case .ocean: Color(hex: 0x0e293b)
        case .forest: Color(hex: 0x142b23)
        }
    }

    // MARK: Lines

    /// Dividers and the hairlines of cards.
    var border: Color { Color(hex: dark ? 0x383a3e : 0xe3e3e3) }
    /// Fields and secondary buttons.
    var borderStrong: Color { Color(hex: dark ? 0x5a5c61 : 0xbbbabb) }

    // MARK: Interaction

    var hover: Color { Color(hex: dark ? 0xffffff : 0x1d1c1d).opacity(dark ? 0.08 : 0.06) }
    var pressed: Color { Color(hex: dark ? 0xffffff : 0x1d1c1d).opacity(dark ? 0.14 : 0.11) }
    /// A quiet tint for what is picked on the canvas: my reactions, search results, the open Preferences tab.
    var selection: Color {
        switch palette {
        case .slate: Color(hex: dark ? 0x293b94 : 0xe7ebff)
        case .aubergine: Color(hex: dark ? 0x713783 : 0xf0e6f4)
        case .ocean: Color(hex: dark ? 0x195b7c : 0xdceef8)
        case .forest: Color(hex: dark ? 0x2d6654 : 0xdeeee5)
        }
    }
    /// The open conversation in the sidebar: Slack's strong fill, under `selectionText`.
    var selectionStrong: Color {
        switch palette {
        case .slate: Color(hex: 0x1164a3)
        case .aubergine: Color(hex: dark ? 0x7c3085 : 0x611f69)
        case .ocean: Color(hex: dark ? 0x0f7aa8 : 0x0b5c8a)
        case .forest: Color(hex: dark ? 0x2a7d5f : 0x1d6b50)
        }
    }
    var selectionText: Color { .white }
    /// Words a search matched, in a result: Slack's yellow.
    var highlight: Color { Color(hex: 0xf2c744).opacity(dark ? 0.3 : 0.5) }
    /// The keyboard focus ring around buttons, rows and fields; the same in every theme, so views without the
    /// appearance store, like an AppKit popover's, can draw it.
    static let focusRing = Color(hex: 0x1d9bd1)
    var focusRing: Color { Self.focusRing }

    // MARK: Accent and status

    /// Links, selected tabs, mine.
    var accent: Color { Color(hex: dark ? 0x8195ff : 0x334ec9) }
    /// The fill behind something of yours, such as your reaction.
    var accentTint: Color { accent.opacity(dark ? 0.2 : 0.1) }
    /// Text and icons on a filled button.
    var onAccent: Color { .white }
    /// Slack's green: the one primary action on a screen.
    var buttonPrimary: Color { Color(hex: 0x007a5a) }
    /// Done and verified marks, in the same green.
    var success: Color { buttonPrimary }
    var destructive: Color { Color(hex: 0xe01e5a) }
    /// Connection trouble and recoverable failures.
    var warning: Color { Color(hex: dark ? 0xf0a030 : 0xc46800) }
    /// Mention badges: the same red as destructive, as in Slack.
    var mention: Color { destructive }
    /// An @Name pill in a message or the composer: Slack's link blue on a pale blue fill.
    var mentionText: Color { Color(hex: dark ? 0x1d9bd1 : 0x1264a3) }
    var mentionFill: Color { Color(hex: 0x1d9bd1).opacity(dark ? 0.18 : 0.1) }
    /// The pill of a mention that notifies you, or everyone: Slack's yellow.
    var mentionYouText: Color { dark ? Color(hex: 0xf2c744) : mentionText }
    var mentionYouFill: Color { Color(hex: 0xf2c744).opacity(dark ? 0.2 : 0.4) }
    var presenceActive: Color { Color(hex: 0x2bac76) }
    var presenceAway: Color { Color(hex: dark ? 0xabadb1 : 0x616061) }

    // MARK: Media

    /// Behind the media viewer: near black in either theme, as in Slack, and opaque so nothing ghosts through.
    var mediaBackdrop: Color { Color(hex: 0x1a1b1e) }
    /// Chips over a photo or video: play, duration and the GIF tag.
    var mediaControl: Color { Color.black.opacity(0.6) }
    /// Over the part of a photo left out, such as outside the crop frame; half black, as in Slack, in either theme.
    var mediaShade: Color { Color.black.opacity(0.5) }
    /// Text and icons over media and in the media viewer.
    var onMedia: Color { .white }
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
    return Color(hex: [0x78669d, 0x447389, 0x9b6e4d, 0x5e805b, 0xa76b7c, 0x607ba3][Int(hash % 6)])
}
