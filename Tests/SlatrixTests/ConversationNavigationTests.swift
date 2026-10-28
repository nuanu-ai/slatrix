import Testing

@testable import Slatrix

struct ConversationNavigationTests {
    private static func room(
        _ id: String, _ name: String, direct: Bool = false, starred: Bool = false, unread: Int = 0,
        marked: Bool = false, muted: Bool = false, spaces: [String] = ["!workspace"], membership: String = "join"
    ) -> ChatRoom {
        var result = ChatRoom(id: id, name: name)
        result.isDirect = direct
        result.favorite = starred
        result.unreadMessages = unread
        result.isMarkedUnread = marked
        result.muted = muted
        result.spaceIDs = spaces
        result.membership = membership
        return result
    }
    private static let rooms = [
        room("dm", "Zed", direct: true, unread: 1, spaces: ["!elsewhere"]),
        room("ten", "Channel 10"),
        room("star-channel", "Beta", starred: true, unread: 2),
        room("outside", "Alpha", unread: 1, spaces: ["!elsewhere"]),
        room("invite", "Aardvark", starred: true, unread: 1, membership: "invite"),
        room("two", "Channel 2", marked: true, muted: true),
        room("star-dm", "Avery", direct: true, starred: true),
        room("left", "Aardvark", starred: true, membership: "leave"),
        room("knock", "Aardvark", starred: true, membership: "knock"),
    ]
    private func next(
        _ id: String?, unread: Bool = false, direction: Int = 1, workspace: String? = "!workspace",
        rooms: [ChatRoom] = rooms
    ) -> String? {
        ConversationNavigation.target(
            rooms: rooms, currentID: id, workspaceID: workspace, unreadOnly: unread, direction: direction)
    }

    @Test("Stepping down visits starred, then channels in natural order, then DMs, joined rooms only")
    func traversalOrder() {
        var visited: [String] = []
        while let target = next(visited.last) { visited.append(target) }
        #expect(visited == ["star-dm", "star-channel", "two", "ten", "dm"])
    }

    @Test(
        "Without a usable selection, navigation enters at the end it moves from",
        arguments: [
            (nil, 1, "star-dm"), (nil, -1, "dm"), ("missing", 1, "star-dm"), ("missing", -1, "dm"),
            ("outside", 1, "star-dm"),
        ] as [(String?, Int, String)])
    func entersAtEndpoint(current: String?, direction: Int, expected: String) {
        #expect(next(current, direction: direction) == expected)
    }

    @Test("Navigation stops at the first and last conversation", arguments: [("star-dm", -1), ("dm", 1)])
    func noWrap(current: String, direction: Int) {
        #expect(next(current, direction: direction) == nil)
    }

    @Test(
        "Unread navigation skips read rooms, keeps muted rooms marked unread, and never wraps",
        arguments: [
            ("star-dm", 1, "star-channel"), ("star-channel", 1, "two"), ("two", 1, "dm"), ("ten", -1, "two"),
            (nil, 1, "star-channel"), (nil, -1, "dm"), ("dm", 1, nil), ("star-dm", -1, nil),
        ] as [(String?, Int, String?)])
    func unreadOnly(current: String?, direction: Int, expected: String?) {
        #expect(next(current, unread: true, direction: direction) == expected)
    }

    @Test("All conversations include rooms outside the selected workspace")
    func allConversations() {
        #expect(next("star-channel", workspace: nil) == "outside")
    }

    @Test("An unknown workspace still includes direct messages")
    func unknownWorkspace() {
        #expect(next("star-dm", workspace: "!unknown") == "dm")
    }

    @Test("No conversations, or no unread one, gives no target")
    func noTarget() {
        #expect(next(nil, workspace: nil, rooms: []) == nil)
        #expect(next("only", unread: true, workspace: nil, rooms: [Self.room("only", "Only")]) == nil)
    }

    @Test("A mention count alone does not make a room unread")
    func mentionsAloneAreNotUnread() {
        var room = Self.room("mentions", "Mentions")
        room.mentions = 4
        #expect(next(nil, unread: true, workspace: nil, rooms: [room]) == nil)
    }

    @Test("Rooms with the same name keep their sidebar order")
    func stableForEqualNames() {
        let rooms = [Self.room("second", "Same"), Self.room("first", "Same")]
        #expect(next(nil, workspace: nil, rooms: rooms) == "second")
        #expect(next("second", workspace: nil, rooms: rooms) == "first")
    }

    @Test("Directions other than one step up or down are refused", arguments: [0, 2, Int.min])
    func invalidDirection(direction: Int) {
        #expect(next(nil, direction: direction) == nil)
    }

    @Test(
        "A conversation picked from #a's Files leaves Files up until it shows, never #a's messages in between",
        arguments: [
            // Still reading its cached rows.
            ("a", "b", ChannelTab.files),
            ("b", "b", .messages),
            // "View in conversation" goes to #a's messages at once.
            ("a", "a", .messages),
            ("a", nil, .messages),
        ] as [(String?, String?, ChannelTab)])
    func screenWhileOpening(showing: String?, opening: String?, expected: ChannelTab) {
        #expect(
            ConversationNavigation.shown(.messages, left: ChannelTab.files, showing: showing, opening: opening)
                == expected)
    }
}
