import Foundation

enum ConversationNavigation {
    static func target(
        rooms: [ChatRoom], currentID: String?, workspaceID: String?, unreadOnly: Bool = false, direction: Int
    ) -> String? {
        let ordered = rooms.enumerated().filter { _, room in
            room.membership == "join" && (room.isDirect || workspaceID == nil || room.spaceIDs.contains(workspaceID!))
        }.sorted { left, right in
            func section(_ room: ChatRoom) -> Int { room.favorite ? 0 : room.isDirect ? 2 : 1 }
            let lhs = section(left.element)
            let rhs = section(right.element)
            if lhs != rhs { return lhs < rhs }
            let comparison = left.element.name.localizedStandardCompare(right.element.name)
            return comparison == .orderedSame ? left.offset < right.offset : comparison == .orderedAscending
        }.map(\.element)
        return step(ordered, from: currentID, unreadOnly: unreadOnly, direction: direction)
    }

    /// The conversation `direction` away from `currentID` in a list as it is shown.
    static func step(_ ordered: [ChatRoom], from currentID: String?, unreadOnly: Bool, direction: Int)
        -> String?
    {
        guard direction == -1 || direction == 1 else { return nil }
        // Anchor in the full list: the currently read room may not be an unread candidate.
        let selected = currentID.flatMap { id in ordered.firstIndex { $0.id == id } }
        var index = selected.map { $0 + direction } ?? (direction == 1 ? 0 : ordered.count - 1)
        while ordered.indices.contains(index) {
            let room = ordered[index]
            if !unreadOnly || room.hasUnread { return room.id }
            index += direction
        }
        return nil
    }
}

/// The tabs under a channel's header, as in Slack.
enum ChannelTab: Hashable { case messages, pins, files }

extension ConversationNavigation {
    /// The screen to draw while a conversation picked on screen `from` opens. Its cached rows take a moment to read,
    /// and until it is the one on screen, `from` stays up, so the conversation open before never flashes back in
    /// between. A conversation already on screen shows `current` at once.
    static func shown<Screen>(_ current: Screen, from: Screen?, showing roomID: String?, opening: String?) -> Screen {
        guard let from, let opening, opening != roomID else { return current }
        return from
    }
}
