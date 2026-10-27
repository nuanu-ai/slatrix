import SwiftUI

/// Slack's conversation header: the name opens details, the member facepile opens Members, and ⋮ holds the rest. A
/// direct message with one person shows them instead, and opens their profile. Reads the member list itself, so
/// members arriving redraw only the header.
struct ChannelHeader: View {
    enum Action: Hashable {
        case details(RoomInfoView.Tab)
        case profile(ChatUser)
        case notifications, star, invite, markUnread, markRead
        case copyLink, search, leave
    }
    let matrix: MatrixService
    let room: ChatRoom
    let perform: (Action) -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        HStack(spacing: m.sp8) {
            if ConversationHeader.isOneToOne(room) {
                Button(action: openPerson) {
                    HStack(spacing: m.sp8) {
                        AvatarView(
                            name: room.name, size: m.avatarMedium, cornerRadius: m.radiusSmall, matrix: matrix,
                            source: room.avatarURL)
                        Text(room.name).font(m.font(.title, .bold)).lineLimit(1)
                    }
                }.buttonStyle(.row).layoutPriority(1)
            } else {
                Button {
                    perform(.details(.about))
                } label: {
                    HStack(spacing: m.sp8) {
                        if !room.isDirect {
                            Image(systemName: room.isEncrypted ? "lock.fill" : "number").font(m.font(.title, .bold))
                        }
                        Text(room.name).font(m.font(.title, .bold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(m.font(.caption, .semibold))
                    }
                }.buttonStyle(.row).layoutPriority(1)
            }
            Spacer()
            if !ConversationHeader.isOneToOne(room) { facepile }
            Menu {
                NativeMessageMenuCommands(commands: Self.menu(for: room, isPreview: matrix.isPreview, perform: perform))
            } label: {
                // A menu's label draws flat, so a rotated "ellipsis" would lie down; SF Symbols has no vertical one.
                Text("⋮").font(m.font(.title, .bold)).frame(width: m.iconButton, height: m.iconButton)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: m.iconButton).help("More actions")
                .accessibilityLabel("More actions")
        }.foregroundStyle(appearance.colors.textPrimary).padding(.horizontal, m.sp20).frame(height: m.paneHeader)
    }

    /// Up to three faces over the header's surface, then the count. Slots for faces not yet loaded hold their place,
    /// so photos arriving move nothing.
    private var facepile: some View {
        let colors = appearance.colors
        let faces = ConversationHeader.faces(matrix.members, me: matrix.user?.id)
        let slots = min(3, max(room.memberCount, faces.count))
        return Button {
            perform(.details(.members))
        } label: {
            HStack(spacing: m.sp4) {
                HStack(spacing: -m.sp8) {
                    ForEach(0..<slots, id: \.self) { index in
                        Group {
                            if index < faces.count {
                                AvatarView(
                                    name: faces[index].name, size: m.avatarMedium, cornerRadius: m.radiusSmall,
                                    matrix: matrix, source: faces[index].avatarURL)
                            } else {
                                RoundedRectangle(cornerRadius: m.radiusSmall).fill(colors.sunken)
                                    .frame(width: m.avatarMedium, height: m.avatarMedium)
                            }
                        }
                        .padding(m.sp2).background(colors.canvas, in: RoundedRectangle(cornerRadius: m.radius))
                        // The first face sits on top, as in Slack.
                        .zIndex(Double(slots - index))
                    }
                }
                Text("\(room.memberCount)").font(m.font(.secondary, .semibold))
            }.padding(.horizontal, m.sp4).frame(height: m.iconButton)
        }.buttonStyle(.icon).help("View all members").accessibilityLabel("\(room.memberCount) members")
    }

    private func openPerson() {
        if let person = matrix.members.first(where: { $0.id != matrix.user?.id }) {
            perform(.profile(person))
        } else {
            perform(.details(.about))
        }
    }

    /// Slack's order: details and preferences, then actions on the conversation, then links, and leaving last.
    static func menu(for room: ChatRoom, isPreview: Bool, perform: @escaping (Action) -> Void) -> [MessageMenuCommand] {
        let noun = room.isDirect ? "conversation" : "channel"
        let joined = !isPreview && room.membership == "join"
        func item(_ id: String, _ title: String, enabled: Bool = true, _ action: Action) -> MessageMenuCommand {
            MessageMenuCommand(id: id, title: title, isEnabled: enabled) { perform(action) }
        }
        return [
            item("details", "Open \(noun) details", .details(.about)),
            item("notifications", "Edit notifications…", enabled: joined, .notifications),
            item("star", room.favorite ? "Unstar \(noun)" : "Star \(noun)", enabled: !isPreview, .star),
            MessageMenuCommand(id: "people-divider", isSeparator: true),
            item("invite", "Invite people…", enabled: joined && room.canInvite != false, .invite),
            item("mark-unread", "Mark unread", enabled: joined, .markUnread),
            item("mark-read", "Mark read", enabled: joined, .markRead),
            MessageMenuCommand(id: "link-divider", isSeparator: true),
            item("copy-link", "Copy link", enabled: !isPreview, .copyLink),
            item("search", "Search in \(noun)", .search),
            MessageMenuCommand(id: "leave-divider", isSeparator: true),
            MessageMenuCommand(id: "leave", title: "Leave \(noun)", isEnabled: joined, isDestructive: true) {
                perform(.leave)
            },
        ]
    }
}
