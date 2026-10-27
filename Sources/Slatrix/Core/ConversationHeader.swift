/// Who a conversation's header shows, as in Slack: a direct message with one other person is about that person, and
/// anything else shows a facepile of its members.
enum ConversationHeader {
    static func isOneToOne(_ room: ChatRoom) -> Bool { room.isDirect && room.memberCount <= 2 }

    /// The facepile: other people before you, three at most.
    static func faces(_ members: [ChatUser], me: String?) -> [ChatUser] {
        Array((members.filter { $0.id != me } + members.filter { $0.id == me }).prefix(3))
    }
}
