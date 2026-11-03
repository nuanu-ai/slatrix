import SwiftUI

/// Slack's DMs view in the sidebar column: every direct message, newest first, beside the one open.
struct DirectMessagesColumn: View {
    let matrix: MatrixService
    @Binding var search: String
    @Binding var unreadOnly: Bool
    let onSelect: (String) -> Void
    let onCompose: () -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    var body: some View {
        let openID = matrix.selectedRoomID
        VStack(spacing: 0) {
            HStack(spacing: m.sp8) {
                Text("Direct messages").font(m.font(.title, .bold)).lineLimit(1)
                Spacer(minLength: m.sp2)
                IconButton(symbol: "square.and.pencil", label: "New message", action: onCompose)
            }.foregroundStyle(appearance.colors.textPrimary).padding(.horizontal, m.sp16).frame(height: m.paneHeader)
            // Slack has Unreads in the header; under the field it leaves the title whole in a sidebar this narrow.
            VStack(alignment: .trailing, spacing: m.sp8) {
                SearchField(prompt: "Find a DM", text: $search)
                Toggle(isOn: $unreadOnly) { Text("Unreads").font(m.font(.secondary)) }.toggleStyle(.switch)
                    .controlSize(.mini)
            }.padding(.horizontal, m.sp12).padding(.bottom, m.sp8)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(
                        ChatRoom.directMessages(
                            matrix.rooms, matching: search, unreadOnly: unreadOnly, keeping: openID)
                    ) { room in
                        Button {
                            onSelect(room.id)
                        } label: {
                            DirectMessageRow(room: room, selected: room.id == openID, matrix: matrix)
                        }.buttonStyle(.row).padding(.horizontal, m.sp8)
                            .accessibilityAddTraits(room.id == openID ? .isSelected : [])
                    }
                }.padding(.bottom, m.sp24)
            }.scrollIndicators(.hidden)
        }
    }
}

/// A row of the DMs list: the newest message under the name, and when it came, as Slack lists them.
struct DirectMessageRow: View {
    let room: ChatRoom
    var selected = false
    var matrix: MatrixService? = nil
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    private var colors: AppColors { appearance.colors }
    var body: some View {
        let badge = UnreadBadge(room)
        HStack(spacing: m.sp8) {
            AvatarView(name: room.name, size: m.avatar, matrix: matrix, source: room.avatarURL)
            VStack(alignment: .leading, spacing: m.sp2) {
                HStack(alignment: .firstTextBaseline, spacing: m.sp8) {
                    Text(room.name).font(m.font(.body, badge != .none ? .bold : .regular))
                        .foregroundStyle(selected ? colors.selectionText : colors.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    if let latest = room.latest {
                        Text(latest.time()).font(m.font(.meta))
                            .foregroundStyle(selected ? colors.selectionText : colors.textSecondary)
                    }
                }
                // A space until the message arrives, so the row keeps its height.
                Text(room.latest?.preview ?? " ").font(m.font(.secondary)).lineLimit(1).foregroundStyle(
                    selected ? colors.selectionText : badge != .none ? colors.textPrimary : colors.textSecondary)
            }
            if case .count(let count) = badge { CountBadge(text: count) }
        }.padding(m.sp8).modifier(SidebarRowFill(selected: selected)).contentShape(Rectangle())
            .accessibilityElement(children: .combine).accessibilityValue(badge != .none ? "Unread" : "")
    }
}
