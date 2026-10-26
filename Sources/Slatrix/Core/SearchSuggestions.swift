import Foundation

/// ⌘K's ranking: names that start with the query, then names with a word that does, then names that contain it; the
/// last visited first within each, then the room list's own recency order.
enum ConversationSwitcher {
    static func results(_ rooms: [ChatRoom], query: String, visited: [String]) -> [ChatRoom] {
        let needle = String(query.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "#" || $0 == "@" })
        let lastVisit = Dictionary(visited.enumerated().map { ($1, $0) }, uniquingKeysWith: max)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return rooms.enumerated().compactMap { index, room -> (tier: Int, recency: Int, room: ChatRoom)? in
            guard room.membership != "leave", !room.isSpace else { return nil }
            let recency = lastVisit[room.id].map { -$0 - 1 } ?? index
            if needle.isEmpty { return (0, recency, room) }
            guard let match = room.name.range(of: needle, options: options) else { return nil }
            if match.lowerBound == room.name.startIndex { return (0, recency, room) }
            let wordStart = room.name.split { !$0.isLetter && !$0.isNumber }.contains {
                $0.range(of: needle, options: options.union(.anchored)) != nil
            }
            return (wordStart ? 1 : 2, recency, room)
        }
        .sorted { ($0.tier, $0.recency) < ($1.tier, $1.recency) }.map(\.room)
    }
}

/// What the top bar's menu offers, top to bottom.
enum SearchSuggestion: Hashable {
    case search(String)
    case recent(String)
    case conversation(ChatRoom)
}

enum SearchSuggestions {
    static func items(query: String, recents: [String], rooms: [ChatRoom], visited: [String]) -> [SearchSuggestion] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recents.prefix(5).map(SearchSuggestion.recent) }
        let matching = recents.filter {
            $0.localizedCaseInsensitiveContains(query) && $0.caseInsensitiveCompare(query) != .orderedSame
        }
        return [.search(query)] + matching.prefix(3).map(SearchSuggestion.recent)
            + ConversationSwitcher.results(rooms, query: query, visited: visited).prefix(5).map(
                SearchSuggestion.conversation)
    }
}

enum RecentSearches {
    static let limit = 10

    static func adding(_ query: String, to recents: [String]) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recents }
        return Array(([query] + recents.filter { $0.caseInsensitiveCompare(query) != .orderedSame }).prefix(limit))
    }
}
