import SwiftUI

/// Slack's red count in a pill that is round for one digit: mentions, and unread direct messages. A neutral one
/// counts what needs no attention, such as a tab's members.
struct CountBadge: View {
    let text: String
    var neutral = false
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        Text(text).font(m.font(.caption, .bold)).monospacedDigit().lineLimit(1)
            .padding(.horizontal, m.sp4).frame(minWidth: m(18), minHeight: m(18))
            .background(neutral ? colors.textSecondary : colors.mention, in: Capsule())
            .foregroundStyle(neutral ? colors.canvas : colors.onAccent)
    }
}

/// A search filter as Slack shows it, for the label of a menu or button: the filter's name and a chevron, tinted
/// once it narrows the results.
struct FilterChip: View {
    let title: String
    let active: Bool
    var menu = true
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        let shape = RoundedRectangle(cornerRadius: m.radius)
        HStack(spacing: m.sp4) {
            Text(title).font(m.font(.secondary, .semibold))
            if menu { Image(systemName: "chevron.down").font(m.font(.caption, .semibold)) }
        }
        .lineLimit(1).foregroundStyle(colors.textPrimary).padding(.horizontal, m.sp12).frame(height: m.controlSmall)
        .background(active ? colors.selection : colors.canvas, in: shape)
        .overlay(shape.strokeBorder(active ? colors.accent : colors.borderStrong))
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
        Text(text).font(m.font(.caption, .semibold)).lineLimit(1).foregroundStyle(colors.textSecondary)
            .padding(.horizontal, m.sp4 + m.sp2).frame(height: m(18))
            .background(colors.sunken, in: RoundedRectangle(cornerRadius: m.radiusSmall))
    }
}
