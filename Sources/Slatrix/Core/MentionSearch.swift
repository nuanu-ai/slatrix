import Foundation

/// Slack's @ autocomplete: the query the caret is in, and who it names, best first.
enum MentionSearch {
    enum Candidate: Hashable {
        case member(ChatUser)
        case room
    }

    struct Suggestions: Equatable {
        /// The @ and the query after it, in UTF-16 offsets: what a chosen mention replaces.
        var range: NSRange
        var candidates: [Candidate]
    }

    /// `text` is everything before the caret; `recentSenders` the conversation's senders, latest first; `offersRoom`
    /// whether your power level lets you notify the room. Nil when the caret isn't in a query that names anyone, so
    /// typing on after a finished name is left alone.
    static func suggestions(
        before text: String, members: [ChatUser], recentSenders: [String], offersRoom: Bool
    ) -> Suggestions? {
        let source = text as NSString
        let at = source.range(of: "@", options: .backwards).location
        guard at != NSNotFound,
            at == 0 || Character(source.substring(with: NSRange(location: at - 1, length: 1))).isWhitespace
        else { return nil }
        let query = source.substring(from: at + 1)
        guard query.first?.isWhitespace != true, !query.contains(where: \.isNewline) else { return nil }
        let candidates = matches(fold(query), members: members, recentSenders: recentSenders, offersRoom: offersRoom)
        guard !candidates.isEmpty else { return nil }
        return Suggestions(range: NSRange(location: at, length: source.length - at), candidates: candidates)
    }

    private static func matches(
        _ query: String, members: [ChatUser], recentSenders: [String], offersRoom: Bool
    ) -> [Candidate] {
        let recency = Dictionary(recentSenders.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let people = members.compactMap { member -> (key: (Int, Int, Int, String, String), member: ChatUser)? in
            guard member.membership == "join" || member.membership == "invite",
                let rank = rank(query, member)
            else { return nil }
            let name = fold(member.name)
            return ((rank, member.membership == "join" ? 0 : 1, recency[member.id] ?? .max, name, member.id), member)
        }.sorted { $0.key < $1.key }.map { Candidate.member($0.member) }
        let room = offersRoom && ["room", "channel", "here"].contains { $0.hasPrefix(query) }
        return people + (room ? [.room] : [])
    }

    /// 0: the name starts with the query; 1: a later word does; 2: the user ID does; 3: it's anywhere in either.
    private static func rank(_ query: String, _ member: ChatUser) -> Int? {
        let name = fold(member.name)
        if name.hasPrefix(query) { return 0 }
        let wordStart = name.indices.dropFirst().contains { index in
            let previous = name[name.index(before: index)]
            return !previous.isLetter && !previous.isNumber && name[index...].hasPrefix(query)
        }
        if wordStart { return 1 }
        let localpart = fold(MatrixID.localpart(member.id))
        if localpart.hasPrefix(query) { return 2 }
        // Across a space only whole words count, so typing on after a mention doesn't keep matching. The server name
        // is left out: everyone on it would match.
        if !query.contains(" ") && (name.contains(query) || localpart.contains(query)) { return 3 }
        return nil
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
