import Testing

@testable import Slatrix

struct ChannelBrowserTests {
    private func channel(_ name: String, members: UInt64 = 5, space: String? = nil) -> PublicDirectoryRoom {
        var room = PublicDirectoryRoom(
            id: "!\(name):example.org", name: name, topic: nil, alias: nil, avatarURL: nil, joinRule: .publicRoom,
            isWorldReadable: false, joinedMembers: members)
        room.spaceName = space
        return room
    }

    private func layout(_ groups: [ChannelBrowser.Group]) -> [String] {
        groups.flatMap { ["[\($0.spaceName ?? "")]"] + $0.channels.map { $0.displayName } }
    }

    // capability: home.browse-channels
    @Test("Channels group under the space that lists them, the workspace's own first, each group by name")
    func groupsByName() {
        let channels = [
            channel("research", space: "Design"), channel("random"), channel("Android", space: "Engineering"),
            channel("design", space: "Design"), channel("General"),
        ]
        #expect(
            layout(ChannelBrowser.groups(channels, sort: .name, hiding: [])) == [
                "[]", "General", "random", "[Design]", "design", "research", "[Engineering]", "Android",
            ])
    }

    @Test("Sorting by members puts the biggest channel of each group first")
    func sortsByMembers() {
        let channels = [channel("small", members: 3), channel("big", members: 90), channel("mid", members: 12)]
        #expect(layout(ChannelBrowser.groups(channels, sort: .members, hiding: [])) == ["[]", "big", "mid", "small"])
    }

    @Test("Hiding your channels drops them, and a group left empty goes with them")
    func hidesJoined() {
        let channels = [channel("general"), channel("design", space: "Design"), channel("random")]
        let hidden: Set = ["!general:example.org", "!design:example.org"]
        #expect(layout(ChannelBrowser.groups(channels, sort: .name, hiding: hidden)) == ["[]", "random"])
    }
}
