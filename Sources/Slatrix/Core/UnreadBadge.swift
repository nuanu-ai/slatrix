/// How a conversation's sidebar row shows it is unread, as in Slack: a red count for mentions and for unread direct
/// messages, a bold name for any other unread channel. A muted conversation shows only mentions, or a name marked
/// unread by hand.
enum UnreadBadge: Equatable {
    case none
    case bold
    /// A red count, which also makes the name bold.
    case count(String)

    init(_ room: ChatRoom) {
        let count =
            room.isDirect && !room.muted ? max(room.mentions, room.unreadMessages, room.unread) : room.mentions
        if count > 0 {
            self = .count(Self.label(count))
        } else if room.isMarkedUnread || (room.hasUnread && !room.muted) {
            self = .bold
        } else {
            self = .none
        }
    }

    static func label(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }
}
