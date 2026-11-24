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

/// The lists a channel opens beside its messages, as Slack's side panel.
enum ChannelPanel: Hashable { case pins, files }

extension ConversationNavigation {
    /// The screen to draw while a conversation picked on screen `from` opens. Its cached rows take a moment to read,
    /// and until it is the one on screen, `from` stays up, so the conversation open before never flashes back in
    /// between. A conversation already on screen shows `current` at once.
    static func shown<Screen>(_ current: Screen, from: Screen?, showing roomID: String?, opening: String?) -> Screen {
        guard let from, let opening, opening != roomID else { return current }
        return from
    }
}

/// Visited conversation stack for Back and Forward navigation.
struct NavigationHistory: Equatable {
    private(set) var entries: [String] = []
    private(set) var index = -1

    var current: String? { entries.indices.contains(index) ? entries[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < entries.count - 1 }
    /// Conversations visited up through the current position.
    var visited: [String] { index >= 0 ? Array(entries.prefix(index + 1)) : [] }

    mutating func record(_ id: String) {
        guard current != id else { return }
        if index + 1 < entries.count { entries = Array(entries.prefix(index + 1)) }
        entries.append(id)
        index = entries.count - 1
    }

    mutating func step(_ delta: Int) -> String? {
        let next = index + delta
        guard entries.indices.contains(next) else { return nil }
        index = next
        return entries[next]
    }

    mutating func jump(to target: Int) -> String? {
        guard entries.indices.contains(target) else { return nil }
        index = target
        return entries[target]
    }
}
