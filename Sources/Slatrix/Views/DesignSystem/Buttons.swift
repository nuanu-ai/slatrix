import SwiftUI

/// What a control looks like right now. Styles derive it from the button; the gallery sets it directly.
enum InteractionState: CaseIterable {
    case rest, hover, pressed, focused, disabled
}

enum ButtonKind: CaseIterable {
    /// The system accent, white text: the one main action on a screen.
    case primary
    /// A control's fill with a hairline edge.
    case secondary
    /// Red, white text: deleting, leaving, signing out.
    case destructive
    /// Accent text that underlines on hover; red for a destructive role.
    case link
}

/// Push buttons, as capsules. Size follows `.controlSize`: small 28, regular 32, large 40.
struct HouseButtonStyle: ButtonStyle {
    let kind: ButtonKind
    var square = false
    func makeBody(configuration: Configuration) -> some View {
        StyledButton(kind: kind, square: square, configuration: configuration)
    }

    private struct StyledButton: View {
        let kind: ButtonKind
        let square: Bool
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focusedWithin
        @State private var hovering = false
        var body: some View {
            ButtonChrome(
                kind: kind,
                state: InteractionState(
                    enabled: enabled, pressed: configuration.isPressed, focused: keyboardFocused(focusedWithin),
                    hovering: hovering), square: square, destructive: configuration.role == .destructive
            ) { configuration.label }
            .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == HouseButtonStyle {
    static var primary: Self { HouseButtonStyle(kind: .primary) }
    static var secondary: Self { HouseButtonStyle(kind: .secondary) }
    /// A square secondary button holding only an icon, such as ⋮ at the end of a row of secondary buttons.
    static var secondaryIcon: Self { HouseButtonStyle(kind: .secondary, square: true) }
    static var destructive: Self { HouseButtonStyle(kind: .destructive) }
    /// `.link` is AppKit's, which ignores the theme's accent.
    static var textLink: Self { HouseButtonStyle(kind: .link) }
}

extension InteractionState {
    init(enabled: Bool, pressed: Bool, focused: Bool, hovering: Bool) {
        self =
            !enabled ? .disabled : pressed ? .pressed : focused ? .focused : hovering ? .hover : .rest
    }
}

/// A push button's look for one state.
struct ButtonChrome<Label: View>: View {
    let kind: ButtonKind
    let state: InteractionState
    var square = false
    var destructive = false
    @ViewBuilder let label: Label
    @Environment(\.metrics) private var m
    @Environment(\.controlSize) private var size
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        if kind == .link {
            label.foregroundStyle(destructive ? colors.destructive : colors.accent).underline(
                state == .hover || state == .pressed
            )
            .opacity(state == .disabled ? 0.4 : state == .pressed ? 0.7 : 1)
            .focusRing(state == .focused, cornerRadius: m.radiusSmall)
        } else {
            let shape = Capsule()
            let height = size == .small || size == .mini ? m.controlSmall : size == .large ? m.controlLarge : m.control
            label.font(m.font(.body, .medium)).lineLimit(1)
                .padding(.horizontal, square ? 0 : size == .small ? m.sp12 : m.sp16)
                .frame(width: square ? height : nil, height: height)
                .foregroundStyle(kind == .secondary ? colors.textPrimary : colors.onAccent)
                .background(fill(colors), in: shape)
                // Hover and press darken a filled button and tint a bordered one.
                .overlay {
                    if state == .hover || state == .pressed {
                        shape.fill(kind == .secondary ? colors.hover : .black.opacity(state == .pressed ? 0.16 : 0.08))
                    }
                }
                .overlay { if kind == .secondary { shape.strokeBorder(colors.borderStrong, lineWidth: 0.5) } }
                .contentShape(shape)
                .opacity(state == .disabled ? 0.4 : 1)
                .focusRing(state == .focused, cornerRadius: height / 2)
        }
    }

    private func fill(_ colors: AppColors) -> Color {
        switch kind {
        case .primary: colors.accentFill
        case .destructive: colors.destructive
        case .secondary, .link: colors.control
        }
    }
}

/// An icon-only button's look: a capsule that fills on hover and press.
struct IconChrome<Label: View>: View {
    let state: InteractionState
    /// A round button with a fill of its own, such as the composer's attach or a pane's close.
    var round = false
    @ViewBuilder let label: Label
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        let fill = state == .pressed ? colors.pressed : state == .hover ? colors.hover : .clear
        Group {
            if round {
                label.contentShape(Circle()).background(fill, in: Circle()).background(colors.sunken, in: Circle())
            } else {
                label.contentShape(Capsule()).background(fill, in: Capsule())
            }
        }
        .opacity(state == .disabled ? 0.4 : 1)
        // A radius past half the side rounds the ring into a capsule.
        .focusRing(state == .focused, cornerRadius: m.iconButton)
    }
}

struct IconButtonStyle: ButtonStyle {
    var round = false
    func makeBody(configuration: Configuration) -> some View { StyledIcon(configuration: configuration, round: round) }

    private struct StyledIcon: View {
        let configuration: Configuration
        let round: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focusedWithin
        @State private var hovering = false
        var body: some View {
            IconChrome(
                state: InteractionState(
                    enabled: enabled, pressed: configuration.isPressed, focused: keyboardFocused(focusedWithin),
                    hovering: hovering), round: round
            ) { configuration.label }
            .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    /// Icon-only buttons in toolbars and the composer.
    static var icon: Self { IconButtonStyle() }
}

struct IconButton: View {
    @Environment(\.metrics) private var m
    let symbol: String
    let label: String
    var role: TextRole = .title3
    /// Square side at 100% zoom; the standard icon button when nil.
    var side: CGFloat? = nil
    var round = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(m.font(role)).frame(
                width: side.map(m.callAsFunction) ?? m.iconButton, height: side.map(m.callAsFunction) ?? m.iconButton
            )
        }
        .buttonStyle(IconButtonStyle(round: round)).help(label).accessibilityLabel(label)
    }
}

/// The house style for borderless buttons: the whole frame takes clicks, including the gaps between an icon,
/// its label and a trailing spacer, which `.plain` leaves dead. A keyboard focus ring shows around the frame.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(label: configuration.label) }

    private struct Row: View {
        let label: Configuration.Label
        @Environment(\.isFocused) private var focusedWithin
        @Environment(\.metrics) private var m
        var body: some View {
            label.contentShape(Rectangle())
                .focusRing(keyboardFocused(focusedWithin), cornerRadius: m.radius)
        }
    }
}

extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
}

/// Whether a button has keyboard focus, given `isFocused` read inside it. Without the Mac's keyboard navigation
/// buttons can't take focus, and `isFocused` then reports a focused container around them instead.
@MainActor func keyboardFocused(_ focusedWithin: Bool) -> Bool {
    focusedWithin && NSApplication.shared.isFullKeyboardAccessEnabled
}

extension View {
    /// The keyboard focus ring: 2 pt outside the shape, so nothing inside moves when focus arrives.
    func focusRing(_ shown: Bool, cornerRadius: CGFloat) -> some View {
        modifier(FocusRing(shown: shown, cornerRadius: cornerRadius))
    }
}

private struct FocusRing: ViewModifier {
    let shown: Bool
    let cornerRadius: CGFloat
    @Environment(\.metrics) private var m

    func body(content: Content) -> some View {
        content.overlay {
            if shown {
                RoundedRectangle(cornerRadius: cornerRadius + m.sp2)
                    .strokeBorder(AppColors.focusRing, lineWidth: m.sp2).padding(-m.sp2)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The toolbar's grouped buttons: a capsule a hair above the canvas.
struct ToolbarCapsule<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder let content: Content
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        HStack(spacing: 0) { content }.padding(.horizontal, padding).frame(height: m.control)
            .background(appearance.colors.control, in: Capsule())
            .elevation(.e1, cornerRadius: m.control / 2)
    }
}
