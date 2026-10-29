import Testing

@testable import Slatrix

@MainActor
struct ChannelHeaderTests {
    private let you = ChatUser(id: "@you:example.org", name: "You")
    private let alex = ChatUser(id: "@alex:example.org", name: "Alex")
    private let julia = ChatUser(id: "@julia:example.org", name: "Julia")
    private let sam = ChatUser(id: "@sam:example.org", name: "Sam")
    private let kim = ChatUser(id: "@kim:example.org", name: "Kim")

    @Test("A direct message with one other person shows that person; a channel or group DM shows a facepile")
    func oneToOne() {
        #expect(ConversationHeader.isOneToOne(ChatRoom(id: "!dm", name: "Alex", isDirect: true, memberCount: 2)))
        #expect(
            !ConversationHeader.isOneToOne(ChatRoom(id: "!group", name: "Alex, Sam", isDirect: true, memberCount: 3)))
        #expect(!ConversationHeader.isOneToOne(ChatRoom(id: "!pair", name: "Pair", memberCount: 2)))
    }

    @Test("The facepile puts other people before you and stops at three")
    func faces() {
        #expect(ConversationHeader.faces([you, alex, julia, sam, kim], me: you.id) == [alex, julia, sam])
        #expect(ConversationHeader.faces([you, alex], me: you.id) == [alex, you])
    }

    private func menu(
        _ room: ChatRoom, isPreview: Bool = false, run: @escaping (ChannelHeader.Action) -> Void = { _ in }
    )
        -> [MessageMenuCommand]
    {
        ChannelHeader.menu(for: room, isPreview: isPreview, perform: run)
    }

    // capability: home.star-toggle
    @Test("⋮ stars and unstars the channel")
    func star() throws {
        var ran: [ChannelHeader.Action] = []
        let room = ChatRoom(id: "!team", name: "Team")
        try #require(menu(room) { ran.append($0) }.first { $0.title == "Star channel" }).perform()
        #expect(ran == [.star])
        var starred = room
        starred.favorite = true
        let titles = menu(starred).map(\.title)
        #expect(titles.contains("Unstar channel") && !titles.contains("Star channel"))
    }

    // capability: channel.leave
    @Test("Every ⋮ item does something of its own, and Leave comes last behind a separator")
    func items() {
        var ran: [ChannelHeader.Action] = []
        let items = menu(ChatRoom(id: "!team", name: "Team")) { ran.append($0) }
        let actions = items.filter { !$0.isSeparator }
        for item in actions { item.perform() }
        #expect(Set(ran).count == actions.count)
        #expect(items.last?.title == "Leave channel" && items.last?.isDestructive == true)
        #expect(items.dropLast().last?.isSeparator == true)
    }
}
