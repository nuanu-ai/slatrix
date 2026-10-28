import Foundation

enum ConversationNavigation {
    static func target(
        rooms: [ChatRoom], currentID: String?, workspaceID: String?, unreadOnly: Bool = false, direction: Int
    ) -> String? {
        guard direction == -1 || direction == 1 else { return nil }
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
    /// What the window shows while `opening`, picked from the screen `left`, reads its cached rows: `left`, until
    /// that conversation replaces it, so no frame shows the conversation open before. One already open shows at once.
    static func shown<Screen>(_ current: Screen, left: Screen?, showing roomID: String?, opening: String?) -> Screen {
        guard let left, let opening, opening != roomID else { return current }
        return left
    }
}
