import Testing

@testable import Slatrix

struct UnreadBadgeTests {
    private static func room(
        direct: Bool = false, messages: Int = 0, notifications: Int = 0, mentions: Int = 0, muted: Bool = false,
        marked: Bool = false
    ) -> ChatRoom {
        var result = ChatRoom(id: "!room", name: "room")
        result.isDirect = direct
        result.unreadMessages = messages
        result.unread = notifications
        result.mentions = mentions
        result.muted = muted
        result.isMarkedUnread = marked
        return result
    }

    @Test(
        "As in Slack, mentions and unread direct messages get a red count; other unread channels only go bold",
        arguments: [
            (room(), UnreadBadge.none),
            (room(messages: 3), .bold),
            (room(notifications: 2), .bold),
            (room(messages: 5, mentions: 2), .count("2")),
            (room(mentions: 99), .count("99")),
            (room(mentions: 100), .count("99+")),
            (room(marked: true), .bold),
            (room(direct: true, messages: 3), .count("3")),
            (room(direct: true, notifications: 2), .count("2")),
            (room(direct: true, messages: 4, notifications: 2), .count("4")),
            (room(direct: true, messages: 120), .count("99+")),
            (room(direct: true, marked: true), .bold),
        ])
    func badge(room: ChatRoom, expected: UnreadBadge) {
        #expect(UnreadBadge(room) == expected)
    }

    @Test(
        "A muted conversation shows nothing unless it mentions you or was marked unread",
        arguments: [
            (room(messages: 7, muted: true), UnreadBadge.none),
            (room(direct: true, messages: 7, muted: true), .none),
            (room(messages: 7, mentions: 1, muted: true), .count("1")),
            (room(direct: true, messages: 7, mentions: 1, muted: true), .count("1")),
            (room(muted: true, marked: true), .bold),
        ])
    func muted(room: ChatRoom, expected: UnreadBadge) {
        #expect(UnreadBadge(room) == expected)
    }

    @Test(
        "The collapsed sidebar's button adds up every conversation's count, else goes bold for any unread one",
        arguments: [
            ([room(), room(messages: 7, muted: true)], UnreadBadge.none),
            ([room(), room(messages: 3)], .bold),
            ([room(messages: 3), room(mentions: 2), room(direct: true, messages: 4)], .count("6")),
            ([room(mentions: 60), room(direct: true, messages: 60)], .count("99+")),
        ])
    func combined(rooms: [ChatRoom], expected: UnreadBadge) {
        #expect(UnreadBadge.combined(rooms) == expected)
    }

    @Test("Conversations you have left or not joined, and workspaces, add nothing")
    func combinedSkipsOthers() {
        var left = Self.room(mentions: 2)
        left.membership = "leave"
        var invited = Self.room(messages: 2)
        invited.membership = "invite"
        var space = Self.room(mentions: 2)
        space.isSpace = true
        #expect(UnreadBadge.combined([left, invited, space]) == .none)
    }
}
