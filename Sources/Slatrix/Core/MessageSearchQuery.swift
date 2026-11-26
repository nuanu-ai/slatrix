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
    // Tantivy's default RemoveLongFilter drops tokens over 40 UTF-8 bytes; reserve 3 bytes for U+FF5A.
    private static let maxPrefixUTF8Bytes = 37

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
                guard roomID == nil else { return nil }
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
        let scalars = input.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            while index < scalars.endIndex, scalars[index].properties.isWhitespace {
                index = scalars.index(after: index)
            }
            guard index < scalars.endIndex else { break }
            var negated = false
            if scalars[index] == "-" {
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next] == "\"" || isWordScalar(scalars[next]) {
                    negated = true
                    index = next
                }
            }
            if scalars[index] == "\"" {
                let contentStart = scalars.index(after: index)
                if let (inner, afterClosing) = scanQuoted(scalars, from: contentStart) {
                    index = afterClosing
                    let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let clause = literal(trimmed)
                        if negated {
                            result.negative.append(clause)
                            result.negativeExactHighlights.append(contentsOf: words(in: trimmed))
                        } else {
                            result.positive.append(clause)
                            result.exactHighlights.append(contentsOf: words(in: trimmed))
                        }
                    }
                    continue
                }
                index = contentStart
                continue
            }
            var chunkEnd = index
            while chunkEnd < scalars.endIndex, !scalars[chunkEnd].properties.isWhitespace, scalars[chunkEnd] != "\"" {
                chunkEnd = scalars.index(after: chunkEnd)
            }
            let chunk = String(scalars[index..<chunkEnd])
            index = chunkEnd
            for raw in rawWords(in: chunk) {
                let (clause, lower, isPrefix) = wordClause(raw)
                if negated {
                    result.negative.append(clause)
                    if isPrefix {
                        result.negativePrefixHighlights.append(lower)
                    } else {
                        result.negativeExactHighlights.append(lower)
                    }
                } else {
                    result.positive.append(clause)
                    if isPrefix {
                        result.prefixHighlights.append(lower)
                    } else {
                        result.exactHighlights.append(lower)
                    }
                }
            }
        }
        return result
    }

    private static func scanQuoted(
        _ scalars: String.UnicodeScalarView, from start: String.UnicodeScalarView.Index
    ) -> (String, String.UnicodeScalarView.Index)? {
        var content = String.UnicodeScalarView()
        var index = start
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\\" {
                let next = scalars.index(after: index)
                if next < scalars.endIndex {
                    let escaped = scalars[next]
                    if escaped != "\"" && escaped != "\\" { content.append(scalar) }
                    content.append(escaped)
                    index = scalars.index(after: next)
                    continue
                }
            }
            if scalar == "\"" {
                return (String(content), scalars.index(after: index))
            }
            content.append(scalar)
            index = scalars.index(after: index)
        }
        return nil
    }

    /// Matches Rust's `char::is_alphanumeric()` (Unicode Letter and Number general categories, excluding combining
    /// marks), so generated range bounds never split into multiple Tantivy tokens.
    private static func isWordScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .decimalNumber, .letterNumber, .otherNumber:
            true
        default:
            false
        }
    }

    private static func rawWords(in value: String) -> [String] {
        value.unicodeScalars.split { !isWordScalar($0) }.map(String.init).filter { !$0.isEmpty }
    }

    private static func words(in value: String) -> [String] {
        rawWords(in: value).map { $0.lowercased() }
    }

    private static func wordClause(_ raw: String) -> (clause: String, lower: String, isPrefix: Bool) {
        let lower = raw.lowercased()
        let lowerClean = lower.unicodeScalars.allSatisfy(isWordScalar)
        if lowerClean && lower.unicodeScalars.count >= minPrefixLength && lower.utf8.count <= maxPrefixUTF8Bytes {
            return ("(body:\(lower)^2 OR body:[\(lower) TO \(lower)\(prefixUpperSuffix)])", lower, true)
        }
        // Keep the original token if lowercasing introduces combining marks (e.g. Turkish İ -> i + U+0307) so Tantivy's
        // SimpleTokenizer keeps it as one token before its LowerCaser runs.
        return ("body:\(lowerClean ? lower : raw)", lower, false)
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
            if parsed.positive.isEmpty && roomID == nil && senderID == nil && date == nil && !parsed.negative.isEmpty {
                exactTerms = parsed.negativeExactHighlights
                prefixTerms = parsed.negativePrefixHighlights
            } else {
                exactTerms = parsed.exactHighlights
                prefixTerms = parsed.prefixHighlights
            }
        }
        guard !exactTerms.isEmpty || !prefixTerms.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        let scalars = body.unicodeScalars
        var start = scalars.startIndex
        while start < scalars.endIndex {
            guard let wordStart = scalars[start...].firstIndex(where: Self.isWordScalar) else { break }
            let wordEnd = scalars[wordStart...].firstIndex { !Self.isWordScalar($0) } ?? scalars.endIndex
            let lower = String(scalars[wordStart..<wordEnd]).lowercased()
            let matched =
                exactTerms.contains(lower)
                || prefixTerms.contains { term in
                    term.unicodeScalars.count >= Self.minPrefixLength ? lower.hasPrefix(term) : lower == term
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
