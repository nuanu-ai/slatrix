import Foundation
import Testing

@testable import Slatrix

struct MessageSearchQueryTests {
    @Test(
        "Blank input never creates an SDK query", arguments: MessageSearchQuery.Mode.allCases,
        ["", " ", "\t\n\r", "\u{00a0}"])
    func blankInput(mode: MessageSearchQuery.Mode, input: String) {
        #expect(MessageSearchQuery(input, mode: mode).sdkQuery() == nil)
    }

    @Test("Surrounding whitespace is trimmed in both modes", arguments: MessageSearchQuery.Mode.allCases)
    func trimsSurroundingWhitespace(mode: MessageSearchQuery.Mode) {
        #expect(MessageSearchQuery("  two words\n", mode: mode).text == "two words")
    }

    @Test(
        "Query mode passes SDK boolean, quote, field and escape syntax through",
        arguments: [
            ("  Browser AND sync OR \"two words\"  ", "Browser AND sync OR \"two words\""),
            (#"body:word\*"#, #"body:word\*"#),
        ])
    func queryModePassesSyntaxThrough(input: String, expected: String) {
        let query = MessageSearchQuery(input)
        #expect(query.mode == .query)
        #expect(query.sdkQuery() == expected)
    }

    @Test(
        "Phrase mode escapes quotes and backslashes inside one quoted literal",
        arguments: [
            ("Browser sync check", "\"Browser sync check\""),
            ("a\"b", "\"a\\\"b\""),
            (#"C:\temp\file"#, #""C:\\temp\\file""#),
            (#"trailing\"#, #""trailing\\""#),
            ("'single'", "\"'single'\""),
            ("a\nb\tc", "\"a\nb\tc\""),
            ("!!!", "\"!!!\""),
        ])
    func phraseModeEscaping(input: String, expected: String) {
        #expect(MessageSearchQuery(input, mode: .phrase).sdkQuery() == expected)
    }

    @Test(
        "Phrase mode text survives the SDK parser as a single literal",
        arguments: [
            "Browser sync check", "  Browser sync check\n", "a\"b", #"C:\temp\file"#,
            #"trailing\"#, #"\"quoted\""#, "\"", "\\", "'single'", "AND OR NOT",
            #"body:term OR * [a TO z] ^2 ~4"#, "line one\nline two\tthree",
            "Привет мир", "hello 👋 world", #"a" OR body:*"#, "\u{00a0}two words\u{00a0}",
            "!!!", "👋", String(repeating: "longword", count: 8),
        ])
    func phraseModeRoundTrips(input: String) throws {
        let query = MessageSearchQuery(input, mode: .phrase)
        let sdkQuery = try #require(query.sdkQuery())
        #expect(parsePhrase(sdkQuery) == query.text)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private static let now = Date(timeIntervalSince1970: 1_793_016_000)  // 2026-10-26 12:00 UTC

    @Test(
        "From and date filters become required clauses on the index's sender and date fields",
        arguments: [
            (
                MessageSearchQuery("budget OR plan", senderID: "@alice:example.org", date: .today),
                #"+(budget OR plan) +sender:"@alice:example.org" +date:[2026-10-26T00:00:00Z TO *]"#
            ),
            (
                MessageSearchQuery("two words", mode: .phrase, date: .week),
                #"+"two words" +date:[2026-10-19T00:00:00Z TO *]"#
            ),
            (MessageSearchQuery(" ", senderID: "@alice:example.org"), #"+sender:"@alice:example.org""#),
        ])
    func filtersBecomeClauses(query: MessageSearchQuery, expected: String) {
        #expect(query.sdkQuery(now: Self.now, calendar: Self.utc) == expected)
    }

    @Test("The In filter narrows the hits, not the query, so it can't search on its own")
    func inFilterStaysOutOfTheQuery() {
        #expect(MessageSearchQuery("budget", roomID: "!design:example.org").sdkQuery() == "budget")
        #expect(MessageSearchQuery("", roomID: "!design:example.org").sdkQuery() == nil)
    }

    private static let rooms = [
        ChatRoom(id: "!design:example.org", name: "Design"),
        ChatRoom(id: "!product:example.org", name: "Product design"),
    ]

    @Test(
        "Slack's in: and from: become filters; anything they can't resolve stays in the text",
        arguments: [
            (
                "in:#design from:@alice:example.org budget",
                MessageSearchQuery("budget", roomID: "!design:example.org", senderID: "@alice:example.org")
            ),
            (#"plan in:"Product design""#, MessageSearchQuery("plan", roomID: "!product:example.org")),
            ("FROM:me plan", MessageSearchQuery("plan", senderID: "@me:example.org")),
            ("in:#nowhere from:alice plan", MessageSearchQuery("in:#nowhere from:alice plan")),
        ])
    func parsesModifiers(input: String, expected: MessageSearchQuery) {
        #expect(MessageSearchQuery.parse(input, rooms: Self.rooms, me: "@me:example.org") == expected)
    }

    @Test("Highlights cover whole words the index matched, in any case, and skip operators")
    func highlights() {
        let body = "Sync the async SYNC job and plan"
        let ranges = MessageSearchQuery("sync AND plan").highlights(in: body)
        #expect(ranges.map { String(body[$0]) } == ["Sync", "SYNC", "plan"])
        let phrase = MessageSearchQuery("the async", mode: .phrase).highlights(in: body)
        #expect(phrase.map { String(body[$0]) } == ["the", "async"])
    }

    @Test("Mode is part of request identity, so switching modes invalidates pending pages")
    func modeIsPartOfIdentity() {
        #expect(MessageSearchQuery("same input") != MessageSearchQuery("same input", mode: .phrase))
        #expect(MessageSearchQuery(" ", mode: .query) != MessageSearchQuery(" ", mode: .phrase))
    }

    /// Reads one double-quoted literal the way the pinned Tantivy grammar does (backslash escapes any character),
    /// returning nil unless the whole query is exactly that literal.
    private func parsePhrase(_ query: String) -> String? {
        var characters = query.makeIterator()
        guard characters.next() == "\"" else { return nil }
        var literal = ""
        while let character = characters.next() {
            switch character {
            case "\\":
                guard let escaped = characters.next() else { return nil }
                literal.append(escaped)
            case "\"":
                return characters.next() == nil ? literal : nil
            default:
                literal.append(character)
            }
        }
        return nil
    }
}
