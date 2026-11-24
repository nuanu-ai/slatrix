import SwiftUI

struct ActivityFeedView: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let activity: ActivityService
    @Binding var workspaceID: String?
    var onOpenMessage: (ActivityItem) -> Void
    var onOpenRoom: (String) -> Void
    var onMarkRoomRead: (ChatRoom) -> Void = { _ in }
    var onMarkItemRead: (ActivityItem) -> Void = { _ in }
    var onMarkAllRead: () -> Void = {}
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var filter = ActivityFilter.all
    @State private var unreadOnly = false
    private enum ActivityFilter: String, CaseIterable {
        case all = "All"
        case mentions = "Mentions"
    }
    private var colors: AppColors { appearance.colors }
    private var scoped: (rooms: [ChatRoom], items: [ActivityItem]) {
        ActivityBadge.scoped(rooms: matrix.rooms, items: activity.items, workspaceID: workspaceID)
    }
    private func filteredItems(
        _ scope: (rooms: [ChatRoom], items: [ActivityItem]), roomsByID: [String: ChatRoom]
    ) -> [ActivityItem] {
        scope.items.filter { item in
            (filter == .all || item.hasMention)
                && (!unreadOnly || ActivityBadge.isUnread(item, room: roomsByID[item.roomID]))
        }
        .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp }
    }
    private func filteredSummaryRooms(_ scope: (rooms: [ChatRoom], items: [ActivityItem])) -> [ChatRoom] {
        scope.rooms.filter { ActivityBadge.isSummaryRoom($0, mentionsOnly: filter == .mentions) }
            .sorted {
                $0.membership == "invite" && $1.membership != "invite"
                    || ($0.membership == $1.membership
                        && $0.name.localizedStandardCompare($1.name) == .orderedAscending)
            }
    }

    var body: some View {
        let scope = scoped
        let roomsByID = Dictionary(scope.rooms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = filteredItems(scope, roomsByID: roomsByID)
        let summaryRooms = filteredSummaryRooms(scope)
        let hasMarkableUnread =
            !matrix.isPreview
            && (scope.rooms.contains { $0.membership == "join" && UnreadBadge($0) != .none }
                || scope.items.contains {
                    $0.kind != .invite && ActivityBadge.isUnread($0, room: roomsByID[$0.roomID])
                })
        VStack(spacing: 0) {
            HStack(spacing: m.sp12) {
                TabBar(tabs: ActivityFilter.allCases.map { .init(value: $0, title: $0.rawValue) }, selection: $filter)
                Spacer()
                if hasMarkableUnread {
                    Button("Mark all as read", action: onMarkAllRead)
                        .buttonStyle(.textLink)
                        .font(m.font(.subheadline, .medium))
                }
                Toggle(isOn: $unreadOnly) { Text("Unreads").font(m.font(.body)) }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                FeedWorkspacePicker(matrix: matrix, workspaceID: $workspaceID)
            }.padding(.horizontal, m.sp20).frame(height: m.tabBar)
            Divider().overlay(colors.border)
            if items.isEmpty && summaryRooms.isEmpty {
                EmptyStateView(
                    symbol: filter == .mentions ? "at" : "bell",
                    title: filter == .mentions
                        ? (unreadOnly ? "No unread mentions" : "No mentions")
                        : "You’re all caught up")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !summaryRooms.isEmpty {
                            sectionLabel(filter == .mentions ? "Mentions" : "Unread")
                            ForEach(summaryRooms) { room in
                                Button {
                                    onOpenRoom(room.id)
                                } label: {
                                    summaryRow(room).modifier(FeedRowHover())
                                }.buttonStyle(.row)
                                    .contextMenu {
                                        if !matrix.isPreview && room.membership == "join" {
                                            Button("Mark as read") { onMarkRoomRead(room) }
                                        }
                                    }
                                Divider().overlay(colors.border).padding(.leading, m.sp20 + m.avatar + m.sp12)
                            }
                        }
                        if !items.isEmpty {
                            sectionLabel("Recent")
                            ForEach(items) { item in
                                let unread = ActivityBadge.isUnread(item, room: roomsByID[item.roomID])
                                Button {
                                    onOpenMessage(item)
                                } label: {
                                    activityRow(item, unread: unread).modifier(FeedRowHover())
                                }.buttonStyle(.row)
                                    .contextMenu {
                                        if !matrix.isPreview && unread && item.kind != .invite {
                                            Button("Mark as read") { onMarkItemRead(item) }
                                        }
                                    }
                                Divider().overlay(colors.border).padding(.leading, m.sp20 + m.avatar + m.sp12)
                            }
                        }
                    }.padding(.bottom, m.sp16)
                        .frame(maxWidth: m(ConversationGrid.collectionWidth), alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            }
        }.background(colors.canvas)
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label).font(m.font(.body, .semibold)).foregroundStyle(colors.textSecondary).padding(
            .horizontal, m.sp20
        ).padding(.top, m.sp20).padding(.bottom, m.sp12)
    }

    private func summaryRow(_ room: ChatRoom) -> some View {
        HStack(spacing: m.sp12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(
                    name: room.name, size: m.avatar, cornerRadius: room.isDirect ? nil : m.radius, matrix: matrix,
                    source: room.avatarURL)
                Image(systemName: room.membership == "invite" ? "envelope.fill" : "bell.fill").font(
                    m.font(.subheadline)
                )
                .padding(m.sp2).background(colors.canvas, in: Circle()).offset(x: m.sp4, y: m.sp4)
            }
            VStack(alignment: .leading, spacing: m.sp4) {
                Text(room.name).font(m.font(.body, .semibold)).foregroundStyle(colors.textPrimary)
                    .lineLimit(1)
                Text(
                    room.membership == "invite"
                        ? (room.isSpace ? "You’re invited to this workspace" : "You’re invited to this conversation")
                        : room.mentions > 0
                            ? (max(room.unreadMessages, room.unread) > 0
                                ? "\(room.mentions) \(room.mentions == 1 ? "mention" : "mentions") · \(max(room.unreadMessages, room.unread)) unread"
                                : "\(room.mentions) \(room.mentions == 1 ? "mention" : "mentions")")
                            : room.unreadMessages > 0 || room.unread > 0
                                ? "\(max(room.unreadMessages, room.unread)) unread messages" : "Marked unread"
                )
                .font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
            }
            Spacer()
            if room.membership == "invite" {
                Text("View invitation").font(m.font(.subheadline)).foregroundStyle(colors.accent)
            } else {
                Circle().fill(colors.accent).frame(width: m.sp8, height: m.sp8).accessibilityLabel(
                    "Unread conversation")
            }
        }.padding(.horizontal, m.sp20).padding(.vertical, m.sp16).contentShape(Rectangle())
    }

    private func activityRow(_ item: ActivityItem, unread: Bool) -> some View {
        HStack(alignment: .top, spacing: m.sp12) {
            AvatarView(
                name: item.senderName.isEmpty ? item.roomName : item.senderName, size: m.avatar, matrix: matrix,
                source: item.avatarURL)
            VStack(alignment: .leading, spacing: m.sp8) {
                HStack(alignment: .firstTextBaseline, spacing: m.sp8) {
                    Text(item.senderName.isEmpty ? item.roomName : item.senderName).font(
                        m.font(.body, unread ? .semibold : .regular)
                    ).foregroundStyle(colors.textPrimary).lineLimit(1)
                    Text(
                        item.kind == .invite
                            ? "invited you"
                            : item.kind == .reaction
                                ? "reacted in \(item.roomName)"
                                : item.hasMention ? "mentioned you" : "in \(item.roomName)"
                    ).font(m.font(.subheadline)).foregroundStyle(colors.textSecondary).lineLimit(1)
                    Spacer()
                    Text(item.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute()).font(
                        m.font(.subheadline)
                    ).foregroundStyle(colors.textSecondary)
                    // As in Slack, a dot marks what you haven't opened.
                    if unread { Circle().fill(colors.accent).frame(width: m.sp8, height: m.sp8) }
                }
                if item.hasMention || item.kind == .invite {
                    Text(item.roomName).font(m.font(.subheadline, .medium)).foregroundStyle(colors.accent)
                        .lineLimit(1)
                }
                Text(
                    item.body.isEmpty
                        ? item.kind == .invite ? "Invitation" : "New message"
                        : item.body
                )
                .font(m.font(.body)).foregroundStyle(colors.textBody).lineLimit(3).multilineTextAlignment(.leading)
                if item.threadRootID != nil {
                    Label("Thread reply", systemImage: "bubble.left.and.bubble.right").font(m.font(.subheadline))
                        .foregroundStyle(colors.textSecondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.hasMention {
                Image(systemName: "at").font(m.font(.body, .semibold)).foregroundStyle(colors.accent)
                    .padding(.top, m.sp2)
            }
        }.padding(.horizontal, m.sp20).padding(.vertical, m.sp16).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(
                Rectangle()
            ).accessibilityValue(unread ? "Unread" : "")
    }
}

/// Hover background for full-bleed collection feed rows (Activity, Drafts).
struct FeedRowHover: ViewModifier {
    @State private var hovering = false
    @ThemeColors private var colors

    func body(content: Content) -> some View {
        content.background(hovering ? colors.hover : .clear).onHover { hovering = $0 }
    }
}
