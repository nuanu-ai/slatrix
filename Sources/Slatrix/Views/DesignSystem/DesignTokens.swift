import AppKit
import SwiftUI

/// Text roles at 100% zoom: the macOS text styles, plus Reading for messages. Views pick a role, never a point size.
enum TextRole: CaseIterable {
    /// 11/14: times, section titles, day dividers, badges, captions.
    case subheadline
    /// 13/16: the sidebar, lists, buttons and fields. Unread is semibold.
    case body
    /// 14/20: messages, their authors, and the composer. The one size off the macOS scale.
    case reading
    /// 15/20: window, thread and sheet titles; the space name.
    case title3
    /// 22/26: page headers and large icons.
    case title1
    /// 26/32: empty states and sign-in.
    case largeTitle
    /// 40: hero glyphs in empty states and sign-in.
    case hero

    var points: CGFloat {
        switch self {
        case .subheadline: 11
        case .body: 13
        case .reading: 14
        case .title3: 15
        case .title1: 22
        case .largeTitle: 26
        case .hero: 40
        }
    }

    /// The style's line height, which AppKit text and multi-line SwiftUI text both keep.
    var lineHeight: CGFloat {
        switch self {
        case .subheadline: 14
        case .body: 16
        case .reading, .title3: 20
        case .title1: 26
        case .largeTitle: 32
        case .hero: 48
        }
    }
}

/// Every size in the UI, scaled by the window zoom. Read it with `@Environment(\.metrics) private var m`.
struct Metrics: Equatable {
    var zoom: CGFloat = 1

    /// Scales a named one-off constant that lives beside its view.
    func callAsFunction(_ points: CGFloat) -> CGFloat { points * zoom }

    func size(_ role: TextRole) -> CGFloat { role.points * zoom }
    func font(_ role: TextRole, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        // The one place a point size becomes a Font; views pick a role.
        .system(
            size: size(role), weight: weight, design: design)
    }
    func nsFont(_ role: TextRole) -> NSFont { .systemFont(ofSize: size(role)) }
    func lineHeight(_ role: TextRole) -> CGFloat { role.lineHeight * zoom }
    /// The gap SwiftUI adds between wrapped lines, so they sit at the role's line height.
    func lineSpacing(_ role: TextRole) -> CGFloat {
        let font = nsFont(role)
        return max(0, lineHeight(role) - (font.ascender - font.descender + font.leading).rounded(.up))
    }

    // 4-pt spacing scale (2 is the hairline half-step).
    var sp2: CGFloat { 2 * zoom }
    var sp4: CGFloat { 4 * zoom }
    var sp8: CGFloat { 8 * zoom }
    var sp12: CGFloat { 12 * zoom }
    var sp16: CGFloat { 16 * zoom }
    var sp20: CGFloat { 20 * zoom }
    var sp24: CGFloat { 24 * zoom }
    var sp32: CGFloat { 32 * zoom }
    var sp40: CGFloat { 40 * zoom }

    /// Radii nest: a row inside the sidebar inside the window. Code spans, mention pills and tags.
    var radiusSmall: CGFloat { 4 * zoom }
    /// Sidebar and list rows, menu items, tiles.
    var radius: CGFloat { 8 * zoom }
    /// Cards, attachments, popovers and menus.
    var radiusLarge: CGFloat { 12 * zoom }
    /// The sidebar, the switcher and modals.
    var radiusPanel: CGFloat { 16 * zoom }
    /// A space's tile at avatar size: spaces are rounded squares, people are round.
    var radiusSpace: CGFloat { 10 * zoom }

    var avatarSmall: CGFloat { 20 * zoom }
    var avatarMedium: CGFloat { 24 * zoom }
    var avatar: CGFloat { 32 * zoom }
    /// A sender beside their messages.
    var messageAvatar: CGFloat { 32 * zoom }
    /// The conversation's centered column: the composer, and what a hovered row fills.
    var conversationColumn: CGFloat { 720 * zoom }
    /// A row of that column, with the margin it keeps from the pane on each side.
    var conversationRow: CGFloat { conversationColumn + 2 * sp12 }
    var avatarLarge: CGFloat { 72 * zoom }
    /// The photo at the top of a profile.
    var profilePhoto: CGFloat { 240 * zoom }
    /// The photo on a person's profile card.
    var contactPhoto: CGFloat { 96 * zoom }
    /// The rounded square behind the icon that labels a detail, such as a profile's contact rows.
    var iconTile: CGFloat { 32 * zoom }
    /// Sidebar rows, list rows, menu-like buttons.
    var row: CGFloat { 28 * zoom }
    /// Square hit target of an icon-only button.
    var iconButton: CGFloat { 28 * zoom }
    /// Text fields, push buttons and the toolbar's capsules.
    var control: CGFloat { 32 * zoom }
    /// A row in a menu-like list: the ⌘K switcher and the search menu.
    var menuRow: CGFloat { 32 * zoom }
    /// Small buttons in dense rows.
    var controlSmall: CGFloat { 28 * zoom }
    /// Modal footers, sign-in, and the composer's single line.
    var controlLarge: CGFloat { 40 * zoom }
    /// Where a tooltip's text wraps.
    var tooltipText: CGFloat { 200 * zoom }
    /// Anchored cards such as the emoji picker.
    var popoverWidth: CGFloat { 320 * zoom }
    /// Modal widths: confirmations, forms, and tabbed or two-column modals.
    var modalSmall: CGFloat { 440 * zoom }
    var modalMedium: CGFloat { 560 * zoom }
    var modalLarge: CGFloat { 680 * zoom }
    var tabBar: CGFloat { 40 * zoom }
    /// A person in a list: a 32 pt photo beside two lines.
    var personRow: CGFloat { 48 * zoom }
    /// How far the sidebar floats in from the window's edges.
    var sidebarInset: CGFloat { 8 * zoom }
    /// The toolbar over the conversation and side panes, and the window buttons' row in the sidebar with the inset
    /// above it, so the window buttons sit at one height whether the sidebar shows or not.
    var paneHeader: CGFloat { 52 * zoom }
}

/// How far a surface floats above the one under it: a hairline edge and a soft shadow, darker in dark mode where
/// shadows barely show.
enum Elevation {
    /// The toolbar's capsules, the composer and chips.
    case e1
    /// Menus, popovers, the switcher, toasts and the jump pill.
    case e2
    /// Modals.
    case e3

    fileprivate var shadow: (opacity: Double, radius: CGFloat, y: CGFloat) {
        switch self {
        case .e1: (0.06, 1.5, 1)
        case .e2: (0.18, 24, 16)
        case .e3: (0.24, 32, 20)
        }
    }

    fileprivate var edge: Double { self == .e1 ? 0.1 : 0.14 }
}

/// Durations and curves. Each is nil under Reduce Motion, so the change is instant.
enum Motion {
    /// Overlays, popovers and modals fading in.
    static var overlay: Animation? { reduced ? nil : .easeOut(duration: overlayDuration) }
    /// `overlay`'s length, for AppKit views; zero under Reduce Motion.
    static var overlayDuration: TimeInterval { reduced ? 0 : 0.12 }
    /// Photos fading in over initials, scroll-to.
    static var content: Animation? { reduced ? nil : .easeOut(duration: 0.12) }
    /// A picture that was waited on since `start`: a late one fades in, a quick one is simply there.
    static func arrival(since start: ContinuousClock.Instant) -> Animation? {
        LoadingPresentation.fadesIn(waited: .now - start) ? content : nil
    }
    /// A message jumped to losing its highlight, slowly enough to follow.
    static var highlight: Animation? { reduced ? nil : .easeOut(duration: 1) }
    /// Side panes easing in beside the conversation.
    static var pane: Animation? { reduced ? nil : .easeOut(duration: 0.15) }
    private static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

extension View {
    /// Lifts a surface to `level`: a shadow, plus a hairline in dark mode where shadows barely show.
    func elevation(_ level: Elevation, cornerRadius: CGFloat) -> some View {
        modifier(ElevationModifier(level: level, cornerRadius: cornerRadius))
    }
}

private struct ElevationModifier: ViewModifier {
    let level: Elevation
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.metrics) private var m

    func body(content: Content) -> some View {
        let shadow = level.shadow
        let dark = scheme == .dark
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder((dark ? Color.white : Color.black).opacity(level.edge), lineWidth: 0.5)
            }
            // One shadow for the surface, not one under every glyph on it.
            .compositingGroup()
            .shadow(
                color: .black.opacity(dark ? min(shadow.opacity * 2.5, 0.6) : shadow.opacity),
                radius: m(shadow.radius), y: m(shadow.y))
    }
}

private struct MetricsKey: EnvironmentKey { static let defaultValue = Metrics() }

extension EnvironmentValues {
    var metrics: Metrics {
        get { self[MetricsKey.self] }
        set { self[MetricsKey.self] = newValue }
    }
}
