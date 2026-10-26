import SwiftUI

/// A person in a list, as in Slack's member list: photo and presence, name, and Matrix ID. Hover tints the row and
/// shows a chevron; a click opens the profile. `selected` marks the row the arrow keys are on.
struct PersonRow: View {
    let name: String
    let userID: String
    var isYou = false
    var presence: Presence? = nil
    var matrix: MatrixService? = nil
    var avatarSource: String? = nil
    var selected = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        Button(action: action) {
            HStack(spacing: m.sp12) {
                AvatarView(name: name, size: m.avatar, presence: presence, matrix: matrix, source: avatarSource)
                VStack(alignment: .leading, spacing: m.sp2) {
                    HStack(spacing: m.sp8) {
                        Text(name).font(m.font(.body, .semibold)).foregroundStyle(colors.textPrimary)
                        if isYou { TagLabel(text: "You") }
                    }
                    Text(userID).font(m.font(.caption)).foregroundStyle(colors.textSecondary)
                }.lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(m.font(.caption, .semibold))
                    .foregroundStyle(colors.textSecondary).opacity(hovering || selected ? 1 : 0)
            }
            .padding(.horizontal, m.sp12).frame(height: m.personRow)
            .background(
                selected ? colors.selection : hovering ? colors.hover : .clear,
                in: RoundedRectangle(cornerRadius: m.radius))
        }
        .buttonStyle(.row).onHover { hovering = $0 }
        .help("View \(name)’s profile").accessibilityLabel("\(name), \(userID)")
        .accessibilityHint("Opens the profile")
    }
}
