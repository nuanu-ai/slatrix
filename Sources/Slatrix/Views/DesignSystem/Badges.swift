import SwiftUI

/// Slack's red count in a pill that is round for one digit: mentions, and unread direct messages.
struct CountBadge: View {
    let text: String
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        Text(text).font(m.font(.caption, .bold)).monospacedDigit().lineLimit(1)
            .padding(.horizontal, m.sp4).frame(minWidth: m(18), minHeight: m(18))
            .background(colors.mention, in: Capsule()).foregroundStyle(colors.onAccent)
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
