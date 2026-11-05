import SwiftUI

/// The conversation's buttons in the toolbar, in one capsule: members, which opens Members; pins and files, which
/// swap the timeline for that list and back; and ⋯ with the rest. Reads the member list itself, so members arriving
/// redraw only the capsule.
struct ChannelHeader: View {
    enum Action: Hashable {
        case details(RoomInfoView.Tab)
        case profile(ChatUser)
        case notifications, star, invite, markUnread, markRead
        case copyLink, search, leave
    }
    let matrix: MatrixService
    let room: ChatRoom
    @Binding var tab: ChannelTab
    let perform: (Action) -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        ToolbarCapsule(padding: m.sp4) {
            if !ConversationHeader.isOneToOne(room) {
                Button {
                    perform(.details(.members))
                } label: {
                    HStack(spacing: m(5)) {
                        Image(systemName: "person.2").font(m.font(.body))
                        Text("\(room.memberCount)").font(m.font(.body)).monospacedDigit()
                    }.padding(.horizontal, m.sp8).frame(height: m.iconButton)
                }.buttonStyle(.icon).help("View all members").accessibilityLabel("\(room.memberCount) members")
            }
            toggle(.pins, symbol: "pin", label: "Pinned", count: room.pinnedEventIDs.count)
                .disabled(matrix.isPreview || room.membership != "join")
            toggle(.files, symbol: "doc.on.doc", label: "Files and links")
            Menu {
                NativeMessageMenuCommands(commands: Self.menu(for: room, isPreview: matrix.isPreview, perform: perform))
            } label: {
                Image(systemName: "ellipsis").font(m.font(.body)).frame(width: m.control, height: m.iconButton)
            }.menuStyle(.button).buttonStyle(.icon).menuIndicator(.hidden).fixedSize().help("More actions")
                .accessibilityLabel("More actions")
        }.foregroundStyle(colors.textSecondary)
    }

    /// Shows a list in the timeline's place, or the timeline again; the accent marks the one showing.
    private func toggle(_ value: ChannelTab, symbol: String, label: String, count: Int = 0) -> some View {
        let shown = tab == value
        return Button {
            tab = shown ? .messages : value
        } label: {
            Image(systemName: shown ? symbol + ".fill" : symbol).font(m.font(.body))
                .foregroundStyle(shown ? appearance.colors.accent : appearance.colors.textSecondary)
                .frame(width: m.control, height: m.iconButton)
        }.buttonStyle(.icon).help(label)
            .accessibilityLabel(count > 0 ? "\(label), \(count)" : label)
            .accessibilityAddTraits(shown ? .isSelected : [])
    }

    /// The conversation's name over its topic. The name opens details, or the person's profile in a direct message
    /// with one person.
    struct Title: View {
        let matrix: MatrixService
        let room: ChatRoom
        let perform: (Action) -> Void
        @Environment(\.metrics) private var m
        @EnvironmentObject private var appearance: AppearanceStore

        var body: some View {
            let colors = appearance.colors
            Button(action: open) {
                HStack(spacing: m.sp8) {
                    if ConversationHeader.isOneToOne(room) {
                        AvatarView(name: room.name, size: m.avatarMedium, matrix: matrix, source: room.avatarURL)
                    }
                    VStack(alignment: .leading, spacing: m(1)) {
                        HStack(spacing: m(3)) {
                            if !room.isDirect {
                                Image(systemName: room.channelSymbol).font(m.font(.body, .medium))
                                    .foregroundStyle(colors.textSecondary)
                            }
                            Text(room.name).font(m.font(.title3, .semibold)).foregroundStyle(colors.textPrimary)
                        }
                        // Who is typing shows under the name, as Telegram shows it, in place of the topic.
                        if let line = typing ?? (room.topic.isEmpty ? nil : room.topic) {
                            Text(line).font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
                        }
                    }.lineLimit(1).truncationMode(.tail).animation(Motion.content, value: typing)
                }
            }.buttonStyle(.row).help(room.isDirect ? room.name : "Open channel details")
                .contextMenu {
                    NativeMessageMenuCommands(
                        commands: ChannelHeader.menu(for: room, isPreview: matrix.isPreview, perform: perform))
                }
        }

        private var typing: String? {
            let names = matrix.typingUsers
            if names.isEmpty { return nil }
            if names.count == 1 { return names[0] + " is typing…" }
            if names.count == 2 { return names.joined(separator: " and ") + " are typing…" }
            return "Several people are typing…"
        }

        private func open() {
            if ConversationHeader.isOneToOne(room),
                let person = matrix.members.first(where: { $0.id != matrix.user?.id })
            {
                perform(.profile(person))
            } else {
                perform(.details(.about))
            }
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
