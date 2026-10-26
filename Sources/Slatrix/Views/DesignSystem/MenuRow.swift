import SwiftUI

/// A row in a menu-like list, as in Slack's switcher and search menu: 32 pt, a 24 pt photo or glyph, the title and a
/// muted detail. The row the arrow keys are on takes the strong selection fill and shows ↵; hover tints the others.
struct MenuRow<Icon: View>: View {
    let title: String
    var detail: String? = nil
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
                icon.frame(width: m.avatarMedium, height: m.avatarMedium)
                    .foregroundStyle(selected ? colors.selectionText : colors.textSecondary)
                Text(title).font(m.font(.body)).foregroundStyle(selected ? colors.selectionText : colors.textPrimary)
                    .layoutPriority(1)
                if let detail {
                    Text(detail).font(m.font(.secondary))
                        .foregroundStyle(selected ? colors.selectionText.opacity(0.8) : colors.textSecondary)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "return").font(m.font(.caption, .semibold))
                        .foregroundStyle(colors.selectionText).accessibilityHidden(true)
                }
            }
            .lineLimit(1).padding(.horizontal, m.sp8).frame(height: m.menuRow)
            .background(
                selected ? colors.selectionStrong : hovering ? colors.hover : .clear,
                in: RoundedRectangle(cornerRadius: m.radius))
        }
        .buttonStyle(.row).onHover { hovering = $0 }
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
