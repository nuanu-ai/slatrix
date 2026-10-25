import Testing

@testable import Slatrix

struct UnreadBadgeTests {
    private static func room(
        messages: Int = 0, notifications: Int = 0, mentions: Int = 0, muted: Bool = false, marked: Bool = false
    ) -> ChatRoom {
        var result = ChatRoom(id: "!room", name: "room")
        result.unreadMessages = messages
        result.unread = notifications
        result.mentions = mentions
        result.muted = muted
        result.isMarkedUnread = marked
        return result
    }

    @Test(
        "A conversation's badge shows mentions first, then its unread count, then a marked-unread dot",
        arguments: [
            (room(), UnreadBadge.none),
            (room(messages: 3), .messages("3")),
            (room(notifications: 2), .messages("2")),
            (room(messages: 4, notifications: 2), .messages("4")),
            (room(messages: 5, mentions: 2), .mentions("2")),
            (room(marked: true), .marked),
            (room(messages: 1, marked: true), .messages("1")),
            (room(messages: 120), .messages("99+")),
            (room(mentions: 100), .mentions("99+")),
        ])
    func badge(room: ChatRoom, expected: UnreadBadge) {
        #expect(UnreadBadge(room) == expected)
    }

    @Test("A muted conversation shows only its mentions, as in Slack")
    func muted() {
        #expect(UnreadBadge(Self.room(messages: 7, muted: true)) == .none)
        #expect(UnreadBadge(Self.room(messages: 7, mentions: 1, muted: true)) == .mentions("1"))
    }
}
