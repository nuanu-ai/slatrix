import SwiftUI

/// A count in the accent, in a capsule that is round for one digit: mentions, unread direct messages, Activity. A
/// neutral one counts what needs no attention, such as a tab's members.
struct CountBadge: View {
    let text: String
    var neutral = false
    /// 16 pt instead of 18, for a badge on a button.
    var small = false
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        let side = m(small ? 16 : 18)
        Text(text).font(m.font(.subheadline, .semibold)).monospacedDigit().lineLimit(1)
            .padding(.horizontal, small ? m.sp4 : m(6)).frame(minWidth: side, minHeight: side)
            .background(neutral ? colors.textSecondary : colors.accentFill, in: Capsule())
            .foregroundStyle(neutral ? colors.canvas : colors.onAccent)
    }
}

/// A search filter, for the label of a menu or button: the filter's name and a chevron in a capsule, tinted once it
/// narrows the results.
struct FilterChip: View {
    let title: String
    let active: Bool
    var menu = true
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        let shape = Capsule()
        HStack(spacing: m.sp4) {
            Text(title).font(m.font(.body))
            if menu { Image(systemName: "chevron.down").font(m.font(.subheadline, .semibold)) }
        }
        .lineLimit(1).foregroundStyle(colors.textPrimary).padding(.horizontal, m.sp12).frame(height: m.controlSmall)
        .background(active ? colors.accentTint : colors.control, in: shape)
        .overlay(shape.strokeBorder(active ? colors.accentLine : colors.borderStrong, lineWidth: 0.5))
        .contentShape(shape)
    }
}

/// A short label beside a name or title, such as "You" or "Invited".
struct TagLabel: View {
    let text: String
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        Text(text).font(m.font(.subheadline, .semibold)).lineLimit(1).foregroundStyle(colors.textSecondary)
            .padding(.horizontal, m.sp4 + m.sp2).frame(height: m(18))
            .background(colors.sunken, in: Capsule())
    }
}
