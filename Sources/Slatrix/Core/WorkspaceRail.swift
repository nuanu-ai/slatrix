import Foundation

/// The workspace icons in the left rail. A nil entry is All: every conversation, as Element's Home.
enum WorkspaceRail {
    /// Top-level workspaces in name order, then All while some channel belongs to no workspace.
    static func entries(workspaces: [Workspace], rooms: [ChatRoom]) -> [Workspace?] {
        let orphans = rooms.contains { $0.membership == "join" && !$0.isDirect && !$0.isSpace && $0.spaceIDs.isEmpty }
        return workspaces.filter(\.isTopLevel) + (orphans ? [nil] : [])
    }

    enum Badge: Equatable {
        case quiet, unread
        case mentions(Int)
    }

    /// What a workspace's icon shows for its channels. Direct messages appear in every workspace, so they mark none.
    static func badge(_ workspaceID: String?, rooms: [ChatRoom]) -> Badge {
        let channels = rooms.filter { room in
            room.membership == "join" && !room.isDirect && !room.isSpace
                && (workspaceID.map(room.spaceIDs.contains) ?? room.spaceIDs.isEmpty)
        }
        let mentions = channels.reduce(0) { $0 + $1.mentions }
        if mentions > 0 { return .mentions(mentions) }
        return channels.contains { $0.hasUnread && !$0.muted } ? .unread : .quiet
    }

    /// How a remembered selection of All is stored.
    static let allToken = "__all__"

    /// The workspace to open: the remembered one while it is still there, else the one holding the conversation on
    /// screen, else the one with the most joined channels, so a first launch lands where the person actually works.
    static func choose(
        remembered: String?, showing: ChatRoom? = nil, workspaces: [Workspace], rooms: [ChatRoom]
    ) -> String? {
        let rail = entries(workspaces: workspaces, rooms: rooms)
        if remembered == allToken, rail.contains(nil) { return nil }
        if let remembered, workspaces.contains(where: { $0.id == remembered }) { return remembered }
        if let showing, !showing.isDirect, let home = home(of: showing, current: nil, workspaces: workspaces) {
            return home
        }
        func channels(_ space: Workspace) -> Int {
            rooms.filter { $0.membership == "join" && !$0.isDirect && !$0.isSpace && $0.spaceIDs.contains(space.id) }
                .count
        }
        return rail.compactMap { $0 }.max { channels($0) < channels($1) }?.id
    }

    /// The workspace to show a channel in: the current one if the channel is in it, else its first top-level one.
    static func home(of room: ChatRoom, current: String?, workspaces: [Workspace]) -> String? {
        if let current, room.spaceIDs.contains(current) { return current }
        return workspaces.first { $0.isTopLevel && room.spaceIDs.contains($0.id) }?.id
    }
}
