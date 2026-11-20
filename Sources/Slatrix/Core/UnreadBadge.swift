/// How a conversation's sidebar row shows it is unread, as in Slack: a red count for mentions and for unread direct
/// messages, a bold name for any other unread channel. A muted conversation shows only mentions, or a name marked
/// unread by hand.
enum UnreadBadge: Equatable {
    case none
    case bold
    /// A red count, which also makes the name bold.
    case count(String)

    init(_ room: ChatRoom) {
        let count = Self.count(room)
        if count > 0 {
            self = .count(Self.label(count))
        } else if room.isMarkedUnread || (room.hasUnread && !room.muted) {
            self = .bold
        } else {
            self = .none
        }
    }

    /// Every joined conversation at once, for the collapsed sidebar's button: their counts added up, else bold while
    /// any row is.
    static func combined(_ rooms: [ChatRoom]) -> UnreadBadge {
        let sum = total(rooms)
        if sum > 0 { return .count(label(sum)) }
        return joined(rooms).contains { UnreadBadge($0) != .none } ? .bold : .none
    }

    /// The Dock's count: the same sum, and none while desktop notifications are off.
    static func dock(_ rooms: [ChatRoom], notifications: Bool) -> Int { notifications ? total(rooms) : 0 }

    private static func joined(_ rooms: [ChatRoom]) -> [ChatRoom] {
        rooms.filter { $0.membership == "join" && !$0.isSpace }
    }

    private static func total(_ rooms: [ChatRoom]) -> Int { joined(rooms).reduce(0) { $0 + count($1) } }

    static func label(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }

    private static func count(_ room: ChatRoom) -> Int {
        room.isDirect && !room.muted ? max(room.mentions, room.unreadMessages, room.unread) : room.mentions
    }
}
