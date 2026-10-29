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
    struct RailRoom: Decodable {
        var id: String
        var spaces: [String]?
        var direct: Bool?
        var membership: String?
        var room: ChatRoom {
            WorkspaceRailTests.room(id, spaces: spaces ?? [], direct: direct ?? false, membership: membership ?? "join")
        }
    }
    struct RailWorkspace: Decodable {
        var id: String
        var name: String
        var topLevel: Bool?
    }
    struct EntriesCase: Decodable, CustomTestStringConvertible {
        var name: String
        var workspaces: [String]
        var rooms: [RailRoom]
        var expected: [String?]
        var testDescription: String { name }
    }
    struct ChooseCase: Decodable, CustomTestStringConvertible {
        var name: String
        var remembered: String?
        var workspaces: [String]
        var busy: Bool?
        var rooms: [RailRoom]?
        var extraRooms: [RailRoom]?
        var showing: String?
        var expected: String?
        var testDescription: String { name }
    }
    struct RailSpec: Decodable {
        var workspaces: [RailWorkspace]
        var entries: [EntriesCase]
        var choose: [ChooseCase]
        var busyRooms: [RailRoom]
        func workspaces(_ ids: [String]) -> [Workspace] {
            ids.map { id in
                let known = workspaces.first { $0.id == id }!
                return Workspace(id: id, name: known.name, isTopLevel: known.topLevel ?? true)
            }
        }
    }
    private static let spec = try! SharedSpec.decode("spec/workspace-rail.json", as: RailSpec.self)

    // capability: home.workspace-switcher
    @Test("The switcher offers the shared cases' workspaces", arguments: spec.entries)
    func entries(spec: EntriesCase) {
        let rail = WorkspaceRail.entries(
            workspaces: Self.spec.workspaces(spec.workspaces), rooms: spec.rooms.map(\.room))
        #expect(rail.map { $0?.id } == spec.expected)
    }

    @Test("The shared cases' workspace opens", arguments: spec.choose)
    func choose(spec: ChooseCase) {
        let base = spec.busy == true ? Self.spec.busyRooms : spec.rooms ?? []
        let rooms = (base + (spec.extraRooms ?? [])).map(\.room)
        #expect(
            WorkspaceRail.choose(
                remembered: spec.remembered, showing: rooms.first { $0.id == spec.showing },
                workspaces: Self.spec.workspaces(spec.workspaces), rooms: rooms) == spec.expected)
    }

    private static let lab = Workspace(id: "!lab", name: "Harbor")
    private static let test = Workspace(id: "!test", name: "Test space")
    private static let nested = Workspace(id: "!nested", name: "Design", isTopLevel: false)

    @Test("The search field names the open workspace or space, and all conversations when none is open")
    func searchPrompt() {
        let workspaces = [Self.lab, Self.test, Self.nested]
        #expect(WorkspaceRail.searchPrompt(workspaceID: "!lab", workspaces: workspaces) == "Search Harbor")
        #expect(WorkspaceRail.searchPrompt(workspaceID: "!nested", workspaces: workspaces) == "Search Design")
        #expect(WorkspaceRail.searchPrompt(workspaceID: nil, workspaces: workspaces) == "Search all conversations")
        // Remembered from last time, before the workspaces have loaded.
        #expect(WorkspaceRail.searchPrompt(workspaceID: "!lab", workspaces: []) == "Search all conversations")
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
