import Foundation
import Testing

@testable import Slatrix

/// Message search, from the shared cases in `spec/search-query.json`.
struct MessageSearchQueryTests {
    struct Room: Decodable {
        var id: String
        var name: String
    }

    struct Parse: Decodable, CustomTestStringConvertible {
        var name: String
        var input: String
        var text: String
        var roomID: String?
        var senderID: String?
        var testDescription: String { name }
    }

    struct Query: Decodable, CustomTestStringConvertible {
        var name: String
        var text: String
        var mode: String
        var senderID: String?
        var roomID: String?
        var date: String?
        var now: String?
        var query: String?
        var testDescription: String { name }
    }

    struct Highlights: Decodable, CustomTestStringConvertible {
        var name: String
        var text: String
        var mode: String
        var body: String
        var words: [String]
        var testDescription: String { name }
    }

    struct Spec: Decodable {
        var parse: [Parse]
        var rooms: [Room]
        var me: String
        var query: [Query]
        var highlights: [Highlights]
    }

    private static let spec = Result { try SharedSpec.decode("spec/search-query.json", as: Spec.self) }
    private static let modes: [String: MessageSearchQuery.Mode] = ["query": .query, "phrase": .phrase]
    private static let dates: [String: SearchDate] = ["today": .today, "week": .week, "month": .month, "year": .year]

    @Test("Slack's in: and from:", arguments: try spec.get().parse)
    func parse(spec: Parse) throws {
        let shared = try Self.spec.get()
        let rooms = shared.rooms.map { ChatRoom(id: $0.id, name: $0.name) }
        let parsed = MessageSearchQuery.parse(spec.input, rooms: rooms, me: shared.me)
        #expect(parsed == MessageSearchQuery(spec.text, roomID: spec.roomID, senderID: spec.senderID))
    }

    @Test("The index query", arguments: try spec.get().query)
    func query(spec: Query) throws {
        let mode = try #require(Self.modes[spec.mode])
        let date = try spec.date.map { try #require(Self.dates[$0]) }
        let now = try spec.now.map { try #require(ISO8601DateFormatter().date(from: $0)) } ?? Date()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let query = MessageSearchQuery(spec.text, mode: mode, roomID: spec.roomID, senderID: spec.senderID, date: date)
        #expect(query.sdkQuery(now: now, calendar: utc) == spec.query)
    }

    @Test("Highlighted words", arguments: try spec.get().highlights)
    func highlights(spec: Highlights) throws {
        let query = MessageSearchQuery(spec.text, mode: try #require(Self.modes[spec.mode]))
        #expect(query.highlights(in: spec.body).map { String(spec.body[$0]) } == spec.words)
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
