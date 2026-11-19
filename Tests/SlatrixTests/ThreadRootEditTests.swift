import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// The SDK's thread timeline holds its root as first sent: an edit to the root arrives in the main timeline.
@MainActor
struct ThreadRootEditTests {
    let room = FakeOpenRoom(
        "!team:example.org",
        cached: [FakeTimelineItem(textEvent("$root", body: "After the edit", edited: true), uniqueID: "root")])
    let service = MatrixService()

    init() {
        room.threadItems = [
            FakeTimelineItem(textEvent("$root", body: "Before the edit"), uniqueID: "root"),
            FakeTimelineItem(textEvent("$reply", body: "A reply"), uniqueID: "reply"),
        ]
        service.configureRoomOpenForChecks(
            client: FakeClient(rooms: [room]), roomList: FakeRoomListService(),
            user: ChatUser(id: "@me:example.org", name: "Me"))
    }

    @Test("A thread opened on an edited message shows the edited text, as the channel does")
    func opensEdited() async throws {
        await service.selectRoom(room.id())
        try await service.loadThread(try #require(service.messages.first))
        #expect(await eventually { service.threadMessages.count == 2 })
        let root = try #require(service.threadMessages.first)
        #expect(root.body == "After the edit" && root.isEdited)
    }

    @Test("Editing a message while its thread is open changes it in the thread too")
    func followsEdit() async throws {
        await service.selectRoom(room.id())
        let main = try #require(room.timelines.all.first)
        main.emit([.reset(values: [FakeTimelineItem(textEvent("$root", body: "Before the edit"), uniqueID: "root")])])
        #expect(await eventually { service.messages.first?.body == "Before the edit" })
        try await service.loadThread(try #require(service.messages.first))
        #expect(await eventually { service.threadMessages.count == 2 })
        let edited = FakeTimelineItem(textEvent("$root", body: "After the edit", edited: true), uniqueID: "root")
        main.emit([.reset(values: [edited])])
        #expect(await eventually { service.threadMessages.first?.body == "After the edit" })
    }

    // capability: message.edit
    @Test("An edit of the root the server refused goes back in the open thread as in the channel")
    func followsRefusedEdit() async throws {
        await service.selectRoom(room.id())
        try await service.loadThread(try #require(service.messages.first))
        #expect(await eventually { service.threadMessages.first?.body == "After the edit" })
        let main = try #require(room.timelines.all.first)
        main.emit([.reset(values: [FakeTimelineItem(textEvent("$root", body: "Before the edit"), uniqueID: "root")])])
        #expect(await eventually { service.messages.first?.body == "Before the edit" })
        let root = try #require(service.threadMessages.first)
        #expect(root.body == "Before the edit" && !root.isEdited)
    }

    /// A thread summary of `count` replies, as the server bundles it with the root.
    private final class Replies: ThreadSummary, @unchecked Sendable {
        let count: UInt64
        init(_ count: UInt64) {
            self.count = count
            super.init(noHandle: .init())
        }
        required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
        override func numReplies() -> UInt64 { count }
        override func latestEvent() -> EmbeddedEventDetails { .unavailable }
    }
    private func root(_ replies: UInt64?) -> FakeTimelineItem {
        var event = textEvent("$root", body: "Before the edit")
        if let replies, case .msgLike(var content) = event.content {
            content.threadSummary = Replies(replies)
            event.content = .msgLike(content: content)
        }
        return FakeTimelineItem(event, uniqueID: "root")
    }

    @Test("The thread's root counts the replies the channel counts under it, as the channel's count changes")
    func followsChannelCount() async throws {
        await service.selectRoom(room.id())
        let main = try #require(room.timelines.all.first)
        main.emit([.reset(values: [root(1)])])
        #expect(await eventually { service.messages.first?.replyCount == 1 })
        try await service.loadThread(try #require(service.messages.first))
        #expect(await eventually { service.threadMessages.count == 2 })
        main.emit([.reset(values: [root(5)])])
        // The thread's own timeline still holds its root as first sent, without a count.
        #expect(await eventually { service.threadMessages.first?.replyCount == 5 })
    }

    @Test("A root from the thread's timeline without a count keeps the count the thread opened with")
    func keepsKnownCount() async throws {
        await service.selectRoom(room.id())
        let main = try #require(room.timelines.all.first)
        // The channel's loaded rows don't reach the root, as for a thread opened from the Threads list.
        main.emit([.reset(values: [FakeTimelineItem(textEvent("$other", body: "Later"), uniqueID: "other")])])
        #expect(await eventually { service.messages.first?.eventID == "$other" })
        // As the Threads list has it, with the count from its summary.
        let event = try #require(root(5).asEvent())
        let opened = try #require(MatrixMapping.message(event, roomID: room.id(), ownUserID: "@me:example.org"))
        try await service.loadThread(opened)
        #expect(await eventually { service.threadMessages.count == 2 })
        #expect(service.threadMessages.first?.replyCount == 5)
    }

    // capability: message.delete
    @Test("Deleting the root while its thread is open shows it deleted in the thread too, in the same row")
    func followsDeletion() async throws {
        await service.selectRoom(room.id())
        try await service.loadThread(try #require(service.messages.first))
        #expect(await eventually { service.threadMessages.count == 2 })
        let row = service.threadMessages.first?.id
        let main = try #require(room.timelines.all.first)
        main.emit([.reset(values: [FakeTimelineItem(textEvent("$root", body: "", redacted: true), uniqueID: "root")])])
        #expect(await eventually { service.messages.first?.isRedacted == true })
        let root = try #require(service.threadMessages.first)
        #expect(root.isRedacted && root.body == ChatMessage.deletedBody && root.id == row)
    }
}
