import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// Runs spec/thread-replies-line.json, the rule both apps share for the line under a thread's root.
struct ThreadRepliesLineTests {
    struct Step: Decodable {
        var loadedToRoot: Bool
        var replies: [String]
        var rootSummary: Int?
        var openedWith: Int?
        var line: Int?
    }
    struct Case: Decodable, CustomTestStringConvertible {
        var name: String
        var steps: [Step]
        var testDescription: String { name }
    }
    struct Spec: Decodable { var cases: [Case] }

    // capability: thread.open
    @Test(
        "The replies line under a thread's root says what every shared case says",
        arguments: try SharedSpec.decode("spec/thread-replies-line.json", as: Spec.self).cases)
    func sharedCase(_ spec: Case) {
        for step in spec.steps {
            let replies = step.replies.enumerated().map { index, state in
                var reply = ChatMessage(
                    id: "r\(index)", roomID: "!room:example.org", senderID: "@alice:example.org", senderName: "Alice",
                    body: "Yes", timestamp: Date(timeIntervalSince1970: 0))
                reply.sendState = state == "deleted" ? "sent" : state
                reply.isRedacted = state == "deleted"
                return reply
            }
            let line = ThreadRepliesLine.count(
                loadedToRoot: step.loadedToRoot, replies: replies, rootSummary: step.rootSummary,
                openedWith: step.openedWith)
            #expect(line == step.line)
        }
    }
}

/// The line as the service works it out for the open thread, from the thread's timeline, its conversation's and the
/// count the pane was opened with.
@MainActor
struct ThreadRepliesLineServiceTests {
    let room = FakeOpenRoom(
        "!team:example.org", cached: [FakeTimelineItem(textEvent("$other", body: "Later"), uniqueID: "other")])
    let service = MatrixService()

    init() {
        service.configureRoomOpenForChecks(
            client: FakeClient(rooms: [room]), roomList: FakeRoomListService(),
            user: ChatUser(id: "@me:example.org", name: "Me"))
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
    private func item(_ id: String, replies: UInt64? = nil, redacted: Bool = false) -> FakeTimelineItem {
        var event = textEvent(id, body: redacted ? "" : "Words", redacted: redacted)
        if let replies, case .msgLike(var content) = event.content {
            content.threadSummary = Replies(replies)
            event.content = .msgLike(content: content)
        }
        return FakeTimelineItem(event, uniqueID: id)
    }
    /// Lets the thread's held page answer that it reached the thread's start.
    private func reachRoot() throws {
        try #require(room.timelines.all.last).startReached = true
        room.pageGate.release()
    }

    // capability: threads.feed
    @Test("Opened from Threads, with no channel holding its root, a thread says the count Threads showed")
    func openedFromThreads() async throws {
        await service.selectRoom(room.id())
        room.pageGate.arm()
        room.threadItems = [item("$third")]
        let feed = ThreadFeedMapping.project(
            [ThreadListItem(rootEvent: threadEvent("$root"), latestEvent: threadEvent("$third"), numReplies: 5)],
            room: ChatRoom(id: room.id(), name: "Team"))
        try await service.loadThread(try #require(feed.first).root)
        #expect(await eventually { service.threadMessages.contains { $0.eventID == "$third" } })
        #expect(service.threadRepliesLine == 5)

        try #require(room.timelines.all.last).emit([.reset(values: [item("$root"), item("$second"), item("$third")])])
        #expect(await eventually { service.threadMessages.count == 3 })
        #expect(service.threadRepliesLine == 5)
        try reachRoot()
        #expect(await eventually { service.threadRepliesLine == 2 })
    }

    @Test("Before the thread loads to its root, the line says the count its root carries in the channel now")
    func followsChannelCount() async throws {
        let main = try #require(await opened(root: item("$root", replies: 3)))
        #expect(service.threadRepliesLine == 3)
        // A reply arrives live before the thread has loaded to its root.
        main.emit([.reset(values: [item("$root", replies: 4)])])
        #expect(await eventually { service.threadRepliesLine == 4 })
        // A copy of the root without a count falls back to the count the pane was opened with.
        main.emit([.reset(values: [item("$root")])])
        #expect(await eventually { service.threadRepliesLine == 3 })
        // A count of zero is zero.
        main.emit([.reset(values: [item("$root", replies: 0)])])
        #expect(await eventually { service.threadRepliesLine == nil })
    }

    @Test("Loaded to its root, the thread counts its own replies, and a deleted last reply takes the line away")
    func countsLoadedReplies() async throws {
        let main = try #require(await opened(root: item("$root", replies: 1), thread: [item("$root"), item("$one")]))
        #expect(service.threadRepliesLine == 1)
        try reachRoot()
        #expect(await eventually { !service.hasMoreThreadHistory })
        try #require(room.timelines.all.last).emit([.reset(values: [item("$root"), item("$one", redacted: true)])])
        #expect(await eventually { service.threadMessages.last?.isRedacted == true })
        // The channel still counts the deleted reply, then drops its count.
        #expect(service.threadRepliesLine == nil)
        main.emit([.reset(values: [item("$root")])])
        #expect(await eventually { service.messages.first?.replyCount == nil })
        #expect(service.threadRepliesLine == nil)
    }

    /// Opens the thread of `root`, which the channel holds, from its replies link, with the thread's first page held.
    private func opened(root: FakeTimelineItem, thread: [FakeTimelineItem]? = nil) async -> FakeLiveTimeline? {
        room.threadItems = thread ?? [item("$reply")]
        await service.selectRoom(room.id())
        guard let main = room.timelines.all.first else { return nil }
        main.emit([.reset(values: [root])])
        guard await eventually({ service.messages.first?.eventID == "$root" }), let opener = service.messages.first
        else { return nil }
        room.pageGate.arm()
        try? await service.loadThread(opener)
        guard await eventually({ service.threadMessages.count == (thread?.count ?? 1) }) else { return nil }
        return main
    }
}
