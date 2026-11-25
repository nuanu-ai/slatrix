import Testing

@testable import Slatrix

struct RecentTimelinesTests {
    @Test("Only the last few conversations stay open; the one left longest ago is handed back to close")
    func bounded() {
        var recent = RecentTimelines<String>()
        var closed: [String] = []
        for index in 0..<(RecentTimelines<String>.capacity + 2) {
            let room = "r\(index)"
            closed += recent.keep(room, for: room)
        }
        #expect(RecentTimelines<String>.capacity == 10)
        #expect(closed == ["r0", "r1"])
        #expect(recent.take("r0") == nil)
        #expect(recent.take("r2") == "r2")
        // Taking a room out to show it frees its place.
        #expect(recent.keep("extra", for: "extra").isEmpty)
    }

    @Test("Coming back to a conversation makes it the most recent again")
    func revisitRefreshes() {
        var recent = RecentTimelines<String>()
        for index in 0..<RecentTimelines<String>.capacity { _ = recent.keep("r\(index)", for: "r\(index)") }
        _ = recent.keep(recent.take("r0")!, for: "r0")
        #expect(recent.keep("next", for: "next") == ["r1"])
    }

    @Test("Signing out hands back every open conversation")
    func removeAll() {
        var recent = RecentTimelines<String>()
        for room in ["a", "b"] { _ = recent.keep(room, for: room) }
        #expect(Set(recent.removeAll()) == ["a", "b"])
        #expect(recent.roomIDs.isEmpty)
    }

    @Test("A custom capacity bounds secondary caches independently")
    func customCapacity() {
        var recent = RecentTimelines<String>(capacity: 2)
        #expect(recent.keep("a", for: "a").isEmpty)
        #expect(recent.keep("b", for: "b").isEmpty)
        #expect(recent.keep("c", for: "c") == ["a"])
    }
}
