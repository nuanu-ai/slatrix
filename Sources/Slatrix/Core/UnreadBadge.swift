/// What a conversation shows at the end of its sidebar row: mentions first, then how many messages are unread, then
/// a dot for one marked unread by hand. A muted conversation only shows mentions, as in Slack.
enum UnreadBadge: Equatable {
    case none
    case mentions(String)
    case messages(String)
    case marked

    init(_ room: ChatRoom) {
        let unread = max(room.unreadMessages, room.unread)
        if room.mentions > 0 {
            self = .mentions(Self.label(room.mentions))
        } else if room.muted {
            self = .none
        } else if unread > 0 {
            self = .messages(Self.label(unread))
        } else if room.isMarkedUnread {
            self = .marked
        } else {
            self = .none
        }
    }

    private static func label(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }
}
