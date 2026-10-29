import SwiftUI

/// Every direct message, newest first, for the DMs page.
struct DirectMessagesView: View {
    let matrix: MatrixService
    let onSelect: (String) -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(ChatRoom.directMessages(matrix.rooms)) { room in
                    Button {
                        onSelect(room.id)
                    } label: {
                        DirectMessageRow(room: room, matrix: matrix)
                    }.buttonStyle(.row)
                    Divider().overlay(appearance.colors.border).padding(.leading, m.sp24 + m.avatar + m.sp12)
                }
            }
        }
    }
}

/// A row of the DMs page: the newest message under the name, and when it came, as Slack lists them.
struct DirectMessageRow: View {
    let room: ChatRoom
    var matrix: MatrixService? = nil
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    private var colors: AppColors { appearance.colors }
    var body: some View {
        HStack(spacing: m.sp12) {
            AvatarView(name: room.name, size: m.avatar, matrix: matrix, source: room.avatarURL)
            VStack(alignment: .leading, spacing: m.sp2) {
                HStack(alignment: .firstTextBaseline, spacing: m.sp8) {
                    Text(room.name).font(m.font(.body, room.hasUnread ? .bold : .regular))
                        .foregroundStyle(colors.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    if let latest = room.latest {
                        Text(latest.time()).font(m.font(.meta)).foregroundStyle(colors.textSecondary)
                    }
                }
                // A space until the message arrives, so the row keeps its height.
                Text(room.latest?.preview ?? " ").font(m.font(.secondary))
                    .foregroundStyle(room.hasUnread ? colors.textPrimary : colors.textSecondary).lineLimit(1)
            }
        }.padding(.horizontal, m.sp24).padding(.vertical, m.sp12).contentShape(Rectangle())
            .accessibilityElement(children: .combine).accessibilityValue(room.hasUnread ? "Unread" : "")
    }
}
