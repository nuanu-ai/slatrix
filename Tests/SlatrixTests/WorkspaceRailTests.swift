import Testing

@testable import Slatrix

struct WorkspaceRailTests {
    private static func room(
        _ id: String, spaces: [String] = [], direct: Bool = false, unread: Int = 0, mentions: Int = 0,
        muted: Bool = false, marked: Bool = false, membership: String = "join"
    ) -> ChatRoom {
        var result = ChatRoom(id: id, name: id)
        result.spaceIDs = spaces
        result.isDirect = direct
        result.unreadMessages = unread
        result.mentions = mentions
        result.muted = muted
        result.isMarkedUnread = marked
        result.membership = membership
        return result
    }
    private static let lab = Workspace(id: "!lab", name: "Harbor")
    private static let test = Workspace(id: "!test", name: "Test space")
    private static let nested = Workspace(id: "!nested", name: "Design", isTopLevel: false)

    @Test("The rail lists top-level workspaces, then All only while a channel belongs to no workspace")
    func entries() {
        let workspaces = [Self.nested, Self.lab, Self.test]
        let inSpaces = [
            Self.room("a", spaces: ["!lab"]), Self.room("dm", direct: true), Self.room("invited", membership: "invite"),
        ]
        #expect(WorkspaceRail.entries(workspaces: workspaces, rooms: inSpaces) == [Self.lab, Self.test])
        #expect(
            WorkspaceRail.entries(workspaces: workspaces, rooms: inSpaces + [Self.room("orphan")])
                == [Self.lab, Self.test, nil])
    }

    @Test(
        "A workspace icon counts its channels' mentions, or goes bold when one of its channel rows would",
        arguments: [
            ([room("a", spaces: ["!lab"], unread: 4)], UnreadBadge.bold),
            (
                [room("a", spaces: ["!lab"], unread: 4, mentions: 2), room("b", spaces: ["!lab"], mentions: 1)],
                .count("3")
            ),
            ([room("a", spaces: ["!lab"], mentions: 60), room("b", spaces: ["!lab"], mentions: 60)], .count("99+")),
            ([room("a", spaces: ["!lab"], unread: 4, muted: true)], .none),
            ([room("a", spaces: ["!lab"], muted: true, marked: true)], .bold),
            ([room("a", spaces: ["!lab"], mentions: 1, muted: true)], .count("1")),
            // Direct messages show in every workspace, so they mark none of them.
            ([room("dm", spaces: ["!lab"], direct: true, unread: 3, mentions: 1)], .none),
            ([room("a", spaces: ["!test"], mentions: 1)], .none),
            ([room("a", spaces: ["!lab"], mentions: 1, membership: "invite")], .none),
        ])
    func badge(rooms: [ChatRoom], expected: UnreadBadge) {
        #expect(WorkspaceRail.badge("!lab", rooms: rooms) == expected)
    }

    @Test("All counts only the channels that belong to no workspace")
    func allBadge() {
        let rooms = [Self.room("a", spaces: ["!lab"], mentions: 5), Self.room("orphan", mentions: 1)]
        #expect(WorkspaceRail.badge(nil, rooms: rooms) == .count("1"))
    }

    private static let alpha = Workspace(id: "!alpha", name: "Alpha")
    private static let busy = [
        room("a", spaces: ["!lab"]), room("b", spaces: ["!lab"]), room("c", spaces: ["!test"]),
        room("d", spaces: ["!alpha"]), room("dm1", spaces: ["!alpha"], direct: true),
        room("dm2", spaces: ["!alpha"], direct: true), room("i1", spaces: ["!alpha"], membership: "invite"),
        room("i2", spaces: ["!alpha"], membership: "invite"),
    ]

    @Test(
        "The remembered workspace opens while it is still there; otherwise the one with the most joined channels",
        arguments: [
            // (remembered, workspaces, rooms, expected)
            (nil, [alpha, lab, test], busy, "!lab"),  // first launch: most channels, not first by name
            ("!test", [alpha, lab, test], busy, "!test"),
            ("!nested", [alpha, lab, nested], busy, "!nested"),  // a space opened from a link
            ("!gone", [alpha, lab, test], busy, "!lab"),  // left since
            ("__all__", [alpha, lab, test], busy + [room("orphan")], nil),
            ("__all__", [alpha, lab, test], busy, "!lab"),  // All left the rail
            (nil, [alpha, test], [room("a", spaces: ["!test"]), room("b", spaces: ["!alpha"])], "!alpha"),  // tie
            (nil, [alpha, nested], [room("a", spaces: ["!nested"]), room("b", spaces: ["!nested"])], "!alpha"),
            (nil, [], [room("orphan")], nil),
        ] as [(String?, [Workspace], [ChatRoom], String?)])
    func choose(remembered: String?, workspaces: [Workspace], rooms: [ChatRoom], expected: String?) {
        #expect(WorkspaceRail.choose(remembered: remembered, workspaces: workspaces, rooms: rooms) == expected)
    }

    @Test(
        "When the remembered choice is gone, the workspace of the conversation on screen wins over the busiest",
        arguments: [("__all__", "!test"), ("!gone", "!test"), ("!lab", "!lab")])
    func keepsShownConversation(remembered: String, expected: String) {
        let joined = Self.room("joined", spaces: ["!test"])
        #expect(
            WorkspaceRail.choose(
                remembered: remembered, showing: joined, workspaces: [Self.alpha, Self.lab, Self.test],
                rooms: Self.busy + [joined]) == expected)
    }

    @Test(
        "Opening a channel from another workspace switches to the workspace it belongs to",
        arguments: [
            // (current, room spaces, expected)
            ("!lab", ["!lab"], "!lab"),
            ("!lab", ["!test"], "!test"),
            ("!lab", ["!nested", "!test"], "!test"),  // a nested space has no icon; its top-level one does
            ("!nested", ["!nested", "!test"], "!nested"),
            ("!lab", [], nil),
        ] as [(String?, [String], String?)])
    func home(current: String?, spaces: [String], expected: String?) {
        #expect(
            WorkspaceRail.home(
                of: Self.room("x", spaces: spaces), current: current, workspaces: [Self.lab, Self.nested, Self.test])
                == expected)
    }
}
