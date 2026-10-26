import SwiftUI

struct ActivityFeedView: View {
    private static let filterWidth: CGFloat = 180
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let activity: ActivityService
    @Binding var workspaceID: String?
    var onOpenMessage: (ActivityItem) -> Void
    var onOpenRoom: (String) -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var filter = ActivityFilter.all
    private enum ActivityFilter: String, CaseIterable {
        case all = "All"
        case mentions = "Mentions"
    }
    private var colors: AppColors { appearance.colors }
    private func inScope(_ roomID: String) -> Bool {
        guard let workspaceID else { return true }
        guard let room = matrix.rooms.first(where: { $0.id == roomID }) else { return false }
        if room.isSpace && room.membership == "invite" { return true }
        return room.isDirect || room.spaceIDs.contains(workspaceID)
    }
    private var items: [ActivityItem] {
        activity.items.filter { item in
            inScope(item.roomID) && (filter == .all || item.hasMention)
                && (item.kind != .invite || matrix.rooms.contains { $0.id == item.roomID && $0.membership == "invite" })
        }
        .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp }
    }
    private var summaryRooms: [ChatRoom] {
        matrix.rooms.filter {
            $0.membership != "leave" && inScope($0.id)
                && ($0.membership == "invite" || (filter == .mentions ? $0.mentions > 0 : $0.hasUnread))
        }
        .sorted {
            $0.membership == "invite" && $1.membership != "invite"
                || ($0.membership == $1.membership && $0.name.localizedStandardCompare($1.name) == .orderedAscending)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: m.sp12) {
                Picker("Activity type", selection: $filter) {
                    ForEach(ActivityFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: m(Self.filterWidth))
                Spacer()
                FeedWorkspacePicker(matrix: matrix, workspaceID: $workspaceID)
            }.padding(.horizontal, m.sp24).frame(height: m.control + m.sp16)
            Divider().overlay(colors.border)
            if items.isEmpty && summaryRooms.isEmpty {
                EmptyStateView(
                    symbol: filter == .mentions ? "at" : "bell",
                    title: filter == .mentions ? "No mentions" : "You’re all caught up")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !summaryRooms.isEmpty {
                            sectionLabel(filter == .mentions ? "MENTIONS" : "UNREAD")
                            ForEach(summaryRooms) { room in
                                Button {
                                    onOpenRoom(room.id)
                                } label: {
                                    summaryRow(room)
                                }.buttonStyle(.row)
                                Divider().overlay(colors.border).padding(.leading, m.sp24 + m.avatar + m.sp12)
                            }
                        }
                        if !items.isEmpty {
                            sectionLabel("RECENT")
                            ForEach(items) { item in
                                Button {
                                    onOpenMessage(item)
                                } label: {
                                    activityRow(item)
                                }.buttonStyle(.row)
                                Divider().overlay(colors.border).padding(.leading, m.sp24 + m.avatar + m.sp12)
                            }
                        }
                    }.padding(.bottom, m.sp16)
                }
            }
        }.background(colors.canvas)
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label).font(m.font(.caption, .semibold)).tracking(0.6).foregroundStyle(colors.textSecondary).padding(
            .horizontal, m.sp24
        ).padding(.top, m.sp20).padding(.bottom, m.sp12)
    }

    private func summaryRow(_ room: ChatRoom) -> some View {
        HStack(spacing: m.sp12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(name: room.name, size: m.avatar, matrix: matrix, source: room.avatarURL)
                Image(systemName: room.membership == "invite" ? "envelope.fill" : "bell.fill").font(m.font(.caption))
                    .padding(m.sp2).background(colors.canvas, in: Circle()).offset(x: m.sp4, y: m.sp4)
            }
            VStack(alignment: .leading, spacing: m.sp4) {
                Text(room.name).font(m.font(.secondary, .semibold)).foregroundStyle(colors.textPrimary)
                    .lineLimit(1)
                Text(
                    room.membership == "invite"
                        ? (room.isSpace ? "You’re invited to this workspace" : "You’re invited to this conversation")
                        : room.mentions > 0
                            ? "\(room.mentions) \(room.mentions == 1 ? "mention" : "mentions") · \(max(room.unreadMessages, room.unread)) unread"
                            : room.unreadMessages > 0 || room.unread > 0
                                ? "\(max(room.unreadMessages, room.unread)) unread messages" : "Marked unread"
                )
                .font(m.font(.meta)).foregroundStyle(colors.textSecondary)
            }
            Spacer()
            if room.membership == "invite" {
                Text("View invitation").font(m.font(.caption)).foregroundStyle(colors.accent)
            } else {
                Circle().fill(colors.accent).frame(width: m.sp8, height: m.sp8).accessibilityLabel(
                    "Unread conversation")
            }
        }.padding(.horizontal, m.sp24).padding(.vertical, m.sp16).contentShape(Rectangle())
    }

    private func activityRow(_ item: ActivityItem) -> some View {
        HStack(alignment: .top, spacing: m.sp12) {
            AvatarView(
                name: item.senderName.isEmpty ? item.roomName : item.senderName, size: m.avatar, matrix: matrix,
                source: item.avatarURL)
            VStack(alignment: .leading, spacing: m.sp8) {
                HStack(alignment: .firstTextBaseline, spacing: m.sp8) {
                    Text(item.senderName.isEmpty ? item.roomName : item.senderName).font(
                        m.font(.secondary, .semibold)
                    ).foregroundStyle(colors.textPrimary).lineLimit(1)
                    Text(
                        item.kind == .invite ? "invited you" : item.hasMention ? "mentioned you" : "in \(item.roomName)"
                    ).font(m.font(.caption)).foregroundStyle(colors.textSecondary).lineLimit(1)
                    Spacer()
                    Text(item.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute()).font(
                        m.font(.caption)
                    ).foregroundStyle(colors.textSecondary)
                }
                if item.hasMention || item.kind == .invite {
                    Text(item.roomName).font(m.font(.caption, .medium)).foregroundStyle(colors.accent)
                        .lineLimit(1)
                }
                Text(
                    item.body.isEmpty
                        ? item.kind == .invite ? "Invitation" : "New message"
                        : item.body
                )
                .font(m.font(.secondary)).foregroundStyle(colors.textBody).lineLimit(3).multilineTextAlignment(.leading)
                if item.threadRootID != nil {
                    Label("Thread reply", systemImage: "bubble.left.and.bubble.right").font(m.font(.caption))
                        .foregroundStyle(colors.textSecondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.hasMention {
                Image(systemName: "at").font(m.font(.secondary, .semibold)).foregroundStyle(colors.accent)
                    .padding(.top, m.sp2)
            }
        }.padding(.horizontal, m.sp24).padding(.vertical, m.sp16).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(
                Rectangle())
    }
}
