import Testing

@testable import Slatrix

struct RecentTimelinesTests {
    @Test("Only the last few conversations stay open; the one left longest ago is handed back to close")
    func bounded() {
        var recent = RecentTimelines<String>()
        var closed: [String] = []
        for room in ["a", "b", "c", "d", "e", "f"] { closed += recent.keep(room, for: room) }
        #expect(closed == ["a", "b"])
        #expect(recent.take("a") == nil)
        #expect(recent.take("c") == "c")
        // Taking a room out to show it frees its place.
        #expect(recent.keep("g", for: "g").isEmpty)
    }

    @Test("Coming back to a conversation makes it the most recent again")
    func revisitRefreshes() {
        var recent = RecentTimelines<String>()
        for room in ["a", "b", "c", "d"] { _ = recent.keep(room, for: room) }
        _ = recent.keep(recent.take("a")!, for: "a")
        #expect(recent.keep("e", for: "e") == ["b"])
    }

    @Test("Signing out hands back every open conversation")
    func removeAll() {
        var recent = RecentTimelines<String>()
        for room in ["a", "b"] { _ = recent.keep(room, for: room) }
        #expect(Set(recent.removeAll()) == ["a", "b"])
        #expect(recent.roomIDs.isEmpty)
    }
}
