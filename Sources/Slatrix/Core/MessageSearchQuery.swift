import Foundation

/// A message search: the text, and Slack's filters. Serializes for the SDK's existing Tantivy query parser, whose
/// index has `body`, `sender` (an exact user ID) and `date` fields. Phrase mode uses one literal: the pinned grammar
/// consumes backslash + any character inside double quotes (tantivy-query-grammar 0.26, simple_term).
struct MessageSearchQuery: Hashable {
    enum Mode: String, CaseIterable, Hashable {
        case query = "Query"
        case phrase = "Phrase"
    }
    let text: String
    var mode: Mode
    /// One conversation's hits; each room has its own index, so this filters hits rather than the query.
    var roomID: String?
    var senderID: String?
    var date: SearchDate?

    init(
        _ input: String, mode: Mode = .query, roomID: String? = nil, senderID: String? = nil, date: SearchDate? = nil
    ) {
        text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mode = mode
        self.roomID = roomID
        self.senderID = senderID
        self.date = date
    }

    func sdkQuery(now: Date = Date(), calendar: Calendar = .current) -> String? {
        let body = text.isEmpty ? nil : mode == .query ? text : Self.literal(text)
        var filters: [String] = []
        if let senderID { filters.append("+sender:" + Self.literal(senderID)) }
        if let date {
            let since = ISO8601DateFormatter().string(from: date.since(now, calendar: calendar))
            filters.append("+date:[\(since) TO *]")
        }
        guard !filters.isEmpty else { return body }
        return ((body.map { mode == .query ? ["+(\($0))"] : ["+" + $0] } ?? []) + filters).joined(separator: " ")
    }

    private static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Reads Slack's `in:` and `from:` out of typed text. A room is named as the sidebar shows it, with an optional
    /// `#` or `@` and quotes around spaces; a person by Matrix ID or `me`. What doesn't resolve stays in the text.
    static func parse(_ input: String, rooms: [ChatRoom], me: String?) -> MessageSearchQuery {
        var words = input.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        var text: [String] = []
        var roomID: String?
        var senderID: String?
        while let word = words.popFirst() {
            let lower = word.lowercased()
            guard let key = ["in:", "from:"].first(where: lower.hasPrefix) else {
                text.append(word)
                continue
            }
            var value = String(word.dropFirst(key.count))
            var consumed = [word]
            if value.hasPrefix("\"") {
                while !(value.count > 1 && value.hasSuffix("\"")), let next = words.popFirst() {
                    value += " " + next
                    consumed.append(next)
                }
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            if key == "in:", roomID == nil {
                let name = value.drop { $0 == "#" || $0 == "@" }
                roomID =
                    rooms.first {
                        $0.membership != "leave" && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
                    }?.id
                if roomID != nil { continue }
            } else if key == "from:", senderID == nil {
                senderID = value.lowercased() == "me" ? me : MatrixID.isValid(value, sigil: "@") ? value : nil
                if senderID != nil { continue }
            }
            text += consumed
        }
        return MessageSearchQuery(text.joined(separator: " "), roomID: roomID, senderID: senderID)
    }

    /// Where the words the index matched appear in `body`. The index lowercases whole words split at anything that
    /// isn't a letter or digit, so a match is a whole word in any case.
    func highlights(in body: String) -> [Range<String.Index>] {
        let operators: Set<String> = mode == .query ? ["AND", "OR", "NOT"] : []
        let terms = Set(
            text.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !operators.contains($0) }.map {
                $0.lowercased()
            })
        var ranges: [Range<String.Index>] = []
        var start = body.startIndex
        while start < body.endIndex {
            guard let wordStart = body[start...].firstIndex(where: { $0.isLetter || $0.isNumber }) else { break }
            let wordEnd = body[wordStart...].firstIndex { !$0.isLetter && !$0.isNumber } ?? body.endIndex
            if terms.contains(body[wordStart..<wordEnd].lowercased()) { ranges.append(wordStart..<wordEnd) }
            start = wordEnd
        }
        return ranges
    }
}

/// Slack's date filter: hits since the start of a day this far back.
enum SearchDate: String, CaseIterable, Hashable {
    case today = "Today"
    case week = "Last 7 days"
    case month = "Last 30 days"
    case year = "Last 12 months"

    func since(_ now: Date, calendar: Calendar) -> Date {
        let back: DateComponents =
            switch self {
            case .today: DateComponents()
            case .week: DateComponents(day: -7)
            case .month: DateComponents(day: -30)
            case .year: DateComponents(month: -12)
            }
        return calendar.startOfDay(for: calendar.date(byAdding: back, to: now) ?? now)
    }
}
