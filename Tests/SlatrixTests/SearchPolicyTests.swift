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

/// Recent searches, from the shared cases in `spec/recent-searches.json`.
struct RecentSearchesTests {
    struct Case: Decodable, CustomTestStringConvertible {
        var name: String
        var recents: [String]
        var query: String
        var expected: [String]
        var testDescription: String { name }
    }

    struct Spec: Decodable {
        var adding: [Case]
        var offered: [Case]
    }

    private static let spec = Result { try SharedSpec.decode("spec/recent-searches.json", as: Spec.self) }

    @Test("A search joins the recent list as in every shared case", arguments: try spec.get().adding)
    func adding(spec: Case) {
        #expect(RecentSearches.adding(spec.query, to: spec.recents) == spec.expected)
    }

    // capability: search.recent
    @Test("The search bar offers recent searches as in every shared case", arguments: try spec.get().offered)
    func offered(spec: Case) {
        let recents = SearchSuggestions.items(query: spec.query, recents: spec.recents, rooms: [], visited: []).compactMap {
            if case .recent(let value) = $0 { value } else { nil }
        }
        #expect(recents == spec.expected)
    }
}

struct SearchSuggestionsTests {
    @Test("Typing offers the search itself first, then matching recent searches, then conversations")
    func typedQuery() {
        let design = room("Design")
        let alex = room("Alex Designer", direct: true)
        let items = SearchSuggestions.items(
            query: "des", recents: ["design review", "launch", "DES"], rooms: [room("Random"), alex, design],
            visited: [])
        #expect(items == [.search("des"), .recent("design review"), .conversation(design), .conversation(alex)])
    }

    @Test("At most five conversations")
    func capped() {
        let rooms = (0..<10).map { room("Design \($0)") }
        let items = SearchSuggestions.items(query: "design", recents: [], rooms: rooms, visited: [])
        #expect(items.filter { if case .conversation = $0 { true } else { false } }.count == 5)
    }
}
