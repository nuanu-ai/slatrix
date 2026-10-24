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
    var rail: CGFloat { 68 * zoom }
    /// Sidebar, channel and side-pane headers share one height so their dividers line up.
    var paneHeader: CGFloat { 56 * zoom }
}

private struct MetricsKey: EnvironmentKey { static let defaultValue = Metrics() }

extension EnvironmentValues {
    var metrics: Metrics {
        get { self[MetricsKey.self] }
        set { self[MetricsKey.self] = newValue }
    }
}

extension View {
    /// Sizes a sheet for the current zoom, kept inside the screen so 200% still fits a laptop.
    func sheetSize(width: CGFloat, height: CGFloat? = nil) -> some View {
        modifier(SheetSize(width: width, height: height))
    }
}

private struct SheetSize: ViewModifier {
    let width: CGFloat
    let height: CGFloat?
    @Environment(\.metrics) private var m
    func body(content: Content) -> some View {
        let screen = NSScreen.main?.visibleFrame.insetBy(dx: 40, dy: 40).size ?? CGSize(width: 1e6, height: 1e6)
        content.frame(width: min(m(width), screen.width), height: height.map { min(m($0), screen.height) })
    }
}
