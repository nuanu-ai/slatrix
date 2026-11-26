import Foundation

/// A message search: the text, and Slack's filters. Serializes for the SDK's existing Tantivy query parser, whose
/// index has `body`, `sender` (an exact user ID) and `date` fields. Query mode requires every word (AND), expands
/// 3+ character words into exact-boosted prefix ranges so inflected forms (such as Russian stems) match, supports
/// quoted phrases and `-term` exclusions, and strips raw punctuation so normal queries never fail parsing.
struct MessageSearchQuery: Hashable {
    enum Mode: String, CaseIterable, Hashable {
        case query = "Query"
        case phrase = "Phrase"
    }
    private static let prefixUpperSuffix = "\u{FF5A}"
    private static let minPrefixLength = 3

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
        var filters: [String] = []
        if let senderID { filters.append("+sender:" + Self.literal(senderID)) }
        if let date {
            let since = ISO8601DateFormatter().string(from: date.since(now, calendar: calendar))
            filters.append("+date:[\(since) TO *]")
        }
        guard !text.isEmpty else { return filters.isEmpty ? nil : filters.joined(separator: " ") }
        if mode == .phrase {
            let phrase = Self.literal(text)
            guard !filters.isEmpty else { return phrase }
            return (["+" + phrase] + filters).joined(separator: " ")
        }
        let parsed = Self.tokenize(text)
        var positive = parsed.positive
        var negative = parsed.negative
        if positive.isEmpty && filters.isEmpty {
            if !negative.isEmpty {
                positive = negative
                negative = []
            } else {
                positive = [Self.literal(text)]
            }
        }
        if positive.count == 1 && negative.isEmpty && filters.isEmpty { return positive[0] }
        return (positive.map { "+" + $0 } + negative.map { "-" + $0 } + filters).joined(separator: " ")
    }

    private struct Tokenized {
        var positive: [String] = []
        var negative: [String] = []
        var exactHighlights: [String] = []
        var prefixHighlights: [String] = []
        var negativeExactHighlights: [String] = []
        var negativePrefixHighlights: [String] = []
    }

    private static func tokenize(_ input: String) -> Tokenized {
        var result = Tokenized()
        var index = input.startIndex
        while index < input.endIndex {
            while index < input.endIndex, input[index].isWhitespace { index = input.index(after: index) }
            guard index < input.endIndex else { break }
            var negated = false
            if input[index] == "-" {
                let next = input.index(after: index)
                if next < input.endIndex,
                    input[next] == "\"" || input[next].isLetter || input[next].isNumber
                {
                    negated = true
                    index = next
                }
            }
            if input[index] == "\"" {
                let contentStart = input.index(after: index)
                if let closing = input[contentStart...].firstIndex(of: "\"") {
                    let inner = String(input[contentStart..<closing]).trimmingCharacters(in: .whitespacesAndNewlines)
                    index = input.index(after: closing)
                    if !inner.isEmpty {
                        let clause = literal(inner)
                        if negated {
                            result.negative.append(clause)
                            result.negativeExactHighlights.append(contentsOf: words(in: inner))
                        } else {
                            result.positive.append(clause)
                            result.exactHighlights.append(contentsOf: words(in: inner))
                        }
                    }
                    continue
                }
                index = contentStart
                continue
            }
            let chunkEnd = input[index...].firstIndex { $0.isWhitespace || $0 == "\"" } ?? input.endIndex
            let chunk = String(input[index..<chunkEnd])
            index = chunkEnd
            for word in words(in: chunk) {
                let clause = wordClause(word)
                if negated {
                    result.negative.append(clause)
                    result.negativePrefixHighlights.append(word)
                } else {
                    result.positive.append(clause)
                    result.prefixHighlights.append(word)
                }
            }
        }
        return result
    }

    private static func words(in value: String) -> [String] {
        value.split { !$0.isLetter && !$0.isNumber }.map { $0.lowercased() }.filter { !$0.isEmpty }
    }

    private static func wordClause(_ word: String) -> String {
        if word.count >= minPrefixLength {
            return "(body:\(word)^2 OR body:[\(word) TO \(word)\(prefixUpperSuffix)])"
        }
        return "body:\(word)"
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

    /// Where the words the index matched appear in `body`. Phrase mode and quoted phrases mark exact whole words;
    /// unquoted query terms mark words starting with any 3+ character positive term or matching a shorter term exactly.
    func highlights(in body: String) -> [Range<String.Index>] {
        let exactTerms: [String]
        let prefixTerms: [String]
        if mode == .phrase {
            exactTerms = Self.words(in: text)
            prefixTerms = []
        } else {
            let parsed = Self.tokenize(text)
            if parsed.positive.isEmpty && senderID == nil && date == nil && !parsed.negative.isEmpty {
                exactTerms = parsed.negativeExactHighlights
                prefixTerms = parsed.negativePrefixHighlights
            } else {
                exactTerms = parsed.exactHighlights
                prefixTerms = parsed.prefixHighlights
            }
        }
        guard !exactTerms.isEmpty || !prefixTerms.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = body.startIndex
        while start < body.endIndex {
            guard let wordStart = body[start...].firstIndex(where: { $0.isLetter || $0.isNumber }) else { break }
            let wordEnd = body[wordStart...].firstIndex { !$0.isLetter && !$0.isNumber } ?? body.endIndex
            let lower = body[wordStart..<wordEnd].lowercased()
            let matched =
                exactTerms.contains(lower)
                || prefixTerms.contains { term in
                    term.count >= Self.minPrefixLength ? lower.hasPrefix(term) : lower == term
                }
            if matched { ranges.append(wordStart..<wordEnd) }
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
