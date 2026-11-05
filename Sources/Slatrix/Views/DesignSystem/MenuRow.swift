import SwiftUI

/// A row in a menu-like list, the ⌘K switcher and the search menu: 32 pt, a 20 pt photo or glyph, the title and a
/// muted detail, and a count while it has mentions. The row the arrow keys are on takes the accent, as a menu's
/// highlighted item does; hover tints the others.
struct MenuRow<Icon: View>: View {
    let title: String
    var detail: String? = nil
    /// Semibold, as an unread conversation is in the sidebar.
    var unread = false
    var badge: String? = nil
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let icon: Icon
    @State private var hovering = false
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        Button(action: action) {
            HStack(spacing: m.sp8) {
                icon.frame(width: m.avatarSmall, height: m.avatarSmall)
                    .foregroundStyle(selected ? colors.onAccent : colors.textTertiary)
                Text(title).font(m.font(.body, unread ? .semibold : .regular))
                    .foregroundStyle(selected ? colors.onAccent : colors.textPrimary).layoutPriority(1)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail).font(m.font(.subheadline))
                        .foregroundStyle(selected ? colors.onAccent.opacity(0.8) : colors.textSecondary)
                }
                if let badge {
                    Text(badge).font(m.font(.subheadline, .semibold)).monospacedDigit()
                        .padding(.horizontal, m(6)).frame(minWidth: m(18), minHeight: m(18))
                        .background(selected ? colors.onAccent : colors.accentFill, in: Capsule())
                        .foregroundStyle(selected ? colors.accentFill : colors.onAccent)
                }
            }
            .lineLimit(1).padding(.leading, m.sp8).padding(.trailing, m.sp12).frame(height: m.menuRow)
            .background(
                selected ? colors.accentFill : hovering ? colors.hover : .clear,
                in: RoundedRectangle(cornerRadius: m.radius))
        }
        .buttonStyle(.row).onHover { hovering = $0 }
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
