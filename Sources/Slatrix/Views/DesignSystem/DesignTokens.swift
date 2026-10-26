import AppKit
import SwiftUI

/// Text roles at 100% zoom, following Slack's hierarchy. Views pick a role, never a point size.
enum TextRole {
    /// 11: badges, counts, keyboard hints, rail labels, "edited".
    case caption
    /// 12: timestamps, status lines, helper text under controls.
    case meta
    /// 13: descriptions, tabs, buttons, search fields, secondary list lines.
    case secondary
    /// 15: messages, sender names, sidebar rows, the composer, primary list lines.
    case body
    /// 18: channel and pane titles, sheet titles.
    case title
    /// 22: page headers and large icons.
    case header
    /// 28: welcome headings.
    case display
    /// 40: hero glyphs in empty states and sign-in.
    case hero

    var points: CGFloat {
        switch self {
        case .caption: 11
        case .meta: 12
        case .secondary: 13
        case .body: 15
        case .title: 18
        case .header: 22
        case .display: 28
        case .hero: 40
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

    /// Badges, chips, hover backgrounds of small icons.
    var radiusSmall: CGFloat { 4 * zoom }
    /// Buttons, fields, sidebar rows, toolbars.
    var radius: CGFloat { 6 * zoom }
    /// Cards, attachments, the composer, popovers.
    var radiusLarge: CGFloat { 8 * zoom }
    /// The conversation panel and large tiles.
    var radiusPanel: CGFloat { 12 * zoom }

    var avatarSmall: CGFloat { 20 * zoom }
    var avatarMedium: CGFloat { 24 * zoom }
    var avatar: CGFloat { 36 * zoom }
    var avatarLarge: CGFloat { 72 * zoom }
    /// Sidebar rows, list rows, menu-like buttons.
    var row: CGFloat { 28 * zoom }
    /// Square hit target of an icon-only button.
    var iconButton: CGFloat { 28 * zoom }
    /// Text fields and push buttons.
    var control: CGFloat { 32 * zoom }
    /// Small buttons in dense rows.
    var controlSmall: CGFloat { 28 * zoom }
    /// Modal footers and sign-in.
    var controlLarge: CGFloat { 36 * zoom }
    /// Anchored cards such as the profile card.
    var popoverWidth: CGFloat { 320 * zoom }
    /// Modal widths: confirmations, forms, and tabbed or two-column modals.
    var modalSmall: CGFloat { 440 * zoom }
    var modalMedium: CGFloat { 560 * zoom }
    var modalLarge: CGFloat { 680 * zoom }
    var tabBar: CGFloat { 40 * zoom }
    /// A person in a list: a 36 pt photo beside two lines.
    var personRow: CGFloat { 48 * zoom }
    var rail: CGFloat { 68 * zoom }
    /// Sidebar, channel and side-pane headers share one height so their dividers line up.
    var paneHeader: CGFloat { 56 * zoom }
}

/// How far a surface floats above the one under it. In dark mode a hairline replaces most of what a shadow shows.
enum Elevation {
    /// Toolbars and chips.
    case e1
    /// Popovers, menus, toasts and the jump pill.
    case e2
    /// Modals.
    case e3

    fileprivate var shadow: (opacity: Double, radius: CGFloat, y: CGFloat) {
        switch self {
        case .e1: (0.12, 3, 2)
        case .e2: (0.14, 8, 3)
        case .e3: (0.25, 24, 8)
        }
    }
}

/// Durations and curves. Each is nil under Reduce Motion, so the change is instant.
enum Motion {
    /// Overlays, popovers and modals fading in.
    static var overlay: Animation? { reduced ? nil : .easeOut(duration: 0.12) }
    /// Photos fading in over initials, scroll-to.
    static var content: Animation? { reduced ? nil : .easeOut(duration: 0.12) }
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
        content
            .overlay {
                if scheme == .dark {
                    RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.white.opacity(0.1))
                }
            }
            .shadow(
                color: .black.opacity(scheme == .dark ? shadow.opacity * 2 : shadow.opacity), radius: m(shadow.radius),
                y: m(shadow.y))
    }
}

private struct MetricsKey: EnvironmentKey { static let defaultValue = Metrics() }

extension EnvironmentValues {
    var metrics: Metrics {
        get { self[MetricsKey.self] }
        set { self[MetricsKey.self] = newValue }
    }
}
