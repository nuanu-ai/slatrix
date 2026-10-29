import Testing

@testable import Slatrix

private func room(_ name: String, direct: Bool = false, membership: String = "join", space: Bool = false) -> ChatRoom {
    ChatRoom(
        id: "!\(name.lowercased().filter(\.isLetter)):example.org", name: name, isDirect: direct,
        membership: membership, isSpace: space)
}

/// Finding a conversation by name, from the shared cases in `spec/conversation-search.json`.
struct ConversationSwitcherTests {
    struct Room: Decodable {
        var name: String
        var direct: Bool?
        var membership: String?
        var space: Bool?
    }

    struct Case: Decodable, CustomTestStringConvertible {
        var name: String
        var rooms: [Room]
        var query: String
        var visited: [String]?
        var expected: [String]
        var testDescription: String { name }
    }

    struct Spec: Decodable { var cases: [Case] }

    // capability: search.rooms
    @Test(
        "Conversation ranking matches the shared cases",
        arguments: try SharedSpec.decode("spec/conversation-search.json", as: Spec.self).cases)
    func results(spec: Case) {
        let rooms = spec.rooms.map {
            room($0.name, direct: $0.direct ?? false, membership: $0.membership ?? "join", space: $0.space ?? false)
        }
        let visited = (spec.visited ?? []).map { name in rooms.first { $0.name == name }!.id }
        #expect(ConversationSwitcher.results(rooms, query: spec.query, visited: visited).map(\.name) == spec.expected)
    }
}

struct SearchSuggestionsTests {
    // capability: search.recent
    @Test("An empty bar offers recent searches only")
    func emptyQuery() {
        #expect(
            SearchSuggestions.items(query: "", recents: ["budget", "launch"], rooms: [room("Design")], visited: [])
                == [.recent("budget"), .recent("launch")])
    }

    @Test("Typing offers the search itself first, then matching recent searches, then conversations")
    func typedQuery() {
        let design = room("Design")
        let alex = room("Alex Designer", direct: true)
        let items = SearchSuggestions.items(
            query: "des", recents: ["design review", "launch", "DES"], rooms: [room("Random"), alex, design],
            visited: [])
        #expect(items == [.search("des"), .recent("design review"), .conversation(design), .conversation(alex)])
    }

    @Test("At most a few recent searches and conversations")
    func capped() {
        let rooms = (0..<10).map { room("Design \($0)") }
        let recents = (0..<10).map { "design \($0)" }
        let items = SearchSuggestions.items(query: "design", recents: recents, rooms: rooms, visited: [])
        #expect(items.filter { if case .recent = $0 { true } else { false } }.count == 3)
        #expect(items.filter { if case .conversation = $0 { true } else { false } }.count == 5)
    }
}

struct RecentSearchesTests {
    @Test("A search moves to the front once, whatever its case or spacing")
    func dedupes() {
        #expect(RecentSearches.adding("  Budget ", to: ["launch", "budget"]) == ["Budget", "launch"])
    }

    @Test("Blank searches aren't kept")
    func ignoresBlank() {
        #expect(RecentSearches.adding(" \n", to: ["launch"]) == ["launch"])
    }

    @Test("Only the newest ten are kept")
    func capped() {
        let full = (0..<10).map { "query \($0)" }
        let next = RecentSearches.adding("newest", to: full)
        #expect(next.count == 10)
        #expect(next.first == "newest")
        #expect(!next.contains("query 9"))
    }
}
