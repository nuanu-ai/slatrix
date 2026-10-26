import Testing

@testable import Slatrix

private func room(_ name: String, direct: Bool = false, membership: String = "join", space: Bool = false) -> ChatRoom {
    ChatRoom(
        id: "!\(name.lowercased().filter(\.isLetter)):example.org", name: name, isDirect: direct,
        membership: membership, isSpace: space)
}

struct ConversationSwitcherTests {
    @Test("A name that starts with the query ranks above one that only contains it, however recent")
    func prefixBeatsSubstring() {
        let rooms = [room("Product design"), room("Design")]
        #expect(
            ConversationSwitcher.results(rooms, query: "des", visited: []).map(\.name) == ["Design", "Product design"])
    }

    @Test("A word that starts with the query ranks above a match inside a word")
    func wordStartBeatsInsideWord() {
        let rooms = [room("Undesigned"), room("Product design")]
        #expect(
            ConversationSwitcher.results(rooms, query: "des", visited: []).map(\.name)
                == ["Product design", "Undesigned"])
    }

    @Test("Among equal matches, the conversation visited last comes first, then the room list's recency order")
    func recentBeatsStale() {
        let rooms = [room("Design crit"), room("Design ops"), room("Design system")]
        let ids = rooms.map(\.id)
        #expect(
            ConversationSwitcher.results(rooms, query: "design", visited: [ids[0], ids[2]]).map(\.name)
                == ["Design system", "Design crit", "Design ops"])
    }

    @Test("A direct message matches the person's first or last name, ignoring case and accents")
    func directMessagesByPersonName() {
        let rooms = [room("Planning"), room("Zoë Liddell", direct: true)]
        #expect(ConversationSwitcher.results(rooms, query: "lid", visited: []).map(\.name) == ["Zoë Liddell"])
        #expect(ConversationSwitcher.results(rooms, query: "@ZOE", visited: []).map(\.name) == ["Zoë Liddell"])
    }

    @Test("A leading # is ignored, and left rooms and workspaces never show")
    func skipsLeftRoomsAndSpaces() {
        let rooms = [room("Design", membership: "leave"), room("Design team", space: true), room("Design")]
        #expect(ConversationSwitcher.results(rooms, query: "#design", visited: []).map(\.membership) == ["join"])
    }

    @Test("With no query, recent conversations come first")
    func emptyQueryListsRecent() {
        let rooms = [room("Alpha"), room("Beta"), room("Gamma")]
        #expect(
            ConversationSwitcher.results(rooms, query: " ", visited: [rooms[2].id]).map(\.name)
                == ["Gamma", "Alpha", "Beta"])
    }
}

struct SearchSuggestionsTests {
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
