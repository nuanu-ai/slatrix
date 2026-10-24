import Testing

@testable import Slatrix

struct MessageSearchQueryTests {
    @Test(
        "Blank input never creates an SDK query", arguments: MessageSearchQuery.Mode.allCases,
        ["", " ", "\t\n\r", "\u{00a0}"])
    func blankInput(mode: MessageSearchQuery.Mode, input: String) {
        #expect(MessageSearchQuery(input, mode: mode).sdkQuery == nil)
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
        #expect(query.sdkQuery == expected)
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
        #expect(MessageSearchQuery(input, mode: .phrase).sdkQuery == expected)
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
        let sdkQuery = try #require(query.sdkQuery)
        #expect(parsePhrase(sdkQuery) == query.text)
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
