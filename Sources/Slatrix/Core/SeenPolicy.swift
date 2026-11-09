/// Who has read each of your messages. A read receipt sits on the newest message its owner has read, so it covers
/// every message above it too.
enum SeenPolicy {
    /// Readers of each of `me`'s messages, by message ID, from oldest to newest `messages`.
    static func readers(_ messages: [(id: String, sender: String, readBy: [String])], me: String) -> [String: [String]]
    {
        var below = Set<String>()
        var result: [String: [String]] = [:]
        for message in messages.reversed() {
            below.formUnion(message.readBy.filter { $0 != me })
            if message.sender == me { result[message.id] = below.sorted() }
        }
        return result
    }
}

extension SeenPolicy {
    /// What each group of your messages shows by its time, by the group's first row: the readers of its newest sent
    /// message. Others' groups and groups still sending show nothing.
    static func headers(_ rows: [TimelineLayout.Row], me: String) -> [String: [String]] {
        let messages = rows.compactMap { row -> ChatMessage? in
            if case .message(let message, _, _) = row.kind { message } else { nil }
        }
        let readers = readers(messages.map { ($0.id, $0.senderID, $0.readBy) }, me: me)
        var result: [String: [String]] = [:]
        var newest: [String]?
        for row in rows.reversed() {
            guard case .message(let message, let grouped, _) = row.kind else { continue }
            if newest == nil, message.senderID == me, message.sendState == "sent" { newest = readers[message.id] }
            if !grouped {
                if message.senderID == me, let newest { result[row.id] = newest }
                newest = nil
            }
        }
        return result
    }

    /// "Seen by Alice, Bob and 3 others"; `name` resolves a member's display name.
    static func tooltip(_ readers: [String], name: (String) -> String?) -> String {
        "Seen by " + MatrixID.listed(readers.map { name($0) ?? MatrixID.localpart($0) })
    }
}
