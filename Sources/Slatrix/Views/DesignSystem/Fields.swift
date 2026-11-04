import SwiftUI

/// A text field's frame: 32 pt with capsule ends, a hairline edge, and the accent's edge and halo while editing.
struct FieldChrome<Content: View>: View {
    let focused: Bool
    var error = false
    @ViewBuilder let content: Content
    @Environment(\.metrics) private var m
    @Environment(\.isEnabled) private var enabled
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        let shape = RoundedRectangle(cornerRadius: m.control / 2)
        let edge = error ? colors.destructive : focused ? colors.accentFill : colors.borderStrong
        content.textFieldStyle(.plain).font(m.font(.body)).foregroundStyle(colors.textPrimary)
            .padding(.horizontal, m.sp12).frame(minHeight: m.control)
            .background(colors.control, in: shape)
            .overlay(shape.strokeBorder(edge, lineWidth: focused || error ? 1 : 0.5))
            // The halo sits outside the frame, so focusing never moves anything.
            .overlay {
                if focused || error {
                    RoundedRectangle(cornerRadius: m.control / 2 + m(3))
                        .strokeBorder(edge.opacity(0.3), lineWidth: m(3)).padding(-m(3))
                }
            }
            .opacity(enabled ? 1 : 0.4)
    }
}

/// `.textFieldStyle(.field)`: the house text field.
struct HouseTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View { Focused(field: configuration) }

    private struct Focused: View {
        let field: TextField<HouseTextFieldStyle._Label>
        @FocusState private var focused: Bool
        var body: some View { FieldChrome(focused: focused) { field.focused($focused) } }
    }
}

extension TextFieldStyle where Self == HouseTextFieldStyle {
    static var field: Self { HouseTextFieldStyle() }
}

/// A search field: a magnifier, the query, ✕ once there is text, and an optional shortcut hint while empty. Esc
/// clears it, or runs `onEscape` instead when the field belongs to something Esc closes.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var hint: String? = nil
    var onEscape: (() -> Void)? = nil
    @FocusState private var focused: Bool
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        FieldChrome(focused: focused) {
            HStack(spacing: m.sp8) {
                Image(systemName: "magnifyingglass").foregroundStyle(colors.textSecondary).accessibilityHidden(true)
                TextField(prompt, text: $text).focused($focused).onExitCommand {
                    if let onEscape { onEscape() } else { text = "" }
                }
                if !text.isEmpty {
                    IconButton(symbol: "xmark.circle.fill", label: "Clear search", role: .body, side: 20) {
                        text = ""
                    }.foregroundStyle(colors.textTertiary)
                } else if let hint {
                    Text(hint).font(m.font(.subheadline)).foregroundStyle(colors.textTertiary).accessibilityHidden(true)
                }
            }
        }
    }
}
