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
    @Test("Opened from Threads, a thread says the count Threads showed until its own timeline holds its root")
    func openedFromThreads() async throws {
        await service.selectRoom(room.id())
        room.pageGate.arm()
        room.threadItems = [item("$third")]
        let feed = ThreadFeedMapping.project(
            [ThreadListItem(rootEvent: threadEvent("$root"), latestEvent: threadEvent("$third"), numReplies: 5)],
            room: ChatRoom(id: room.id(), name: "Team"))
        let root = try #require(feed.first).root
        try await service.loadThread(root, openedWith: root.replyCount)
        #expect(await eventually { service.threadMessages.contains { $0.eventID == "$third" } })
        #expect(service.threadRepliesLine == 5)
        // The thread says it reached its start before its root has come.
        try reachRoot()
        #expect(await eventually { !service.hasMoreThreadHistory })
        #expect(service.threadRepliesLine == 5)
        try #require(room.timelines.all.last).emit([.reset(values: [item("$root"), item("$second"), item("$third")])])
        #expect(await eventually { service.threadRepliesLine == 2 })
    }

    @Test("Opened with its thread read to its root ahead of the click, the line counts its replies at once")
    func preparedLoadedCountsReplies() async throws {
        room.threadItems = [item("$root"), item("$one"), item("$two")]
        await service.selectRoom(room.id())
        try #require(room.timelines.all.first).emit([.reset(values: [item("$root", replies: 5)])])
        #expect(await eventually { service.messages.first?.eventID == "$root" })
        let root = try #require(service.messages.first)
        room.pageGate.arm()
        service.prepareThread(root)
        #expect(await eventually { room.pageGate.isWaiting })
        try #require(room.timelines.all.last).startReached = true
        room.pageGate.release()
        try await service.loadThread(root, openedWith: 5)
        #expect(service.threadRepliesLine == 2)
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
        // Before the thread loads, a count of zero says nothing: the device may know the thread only from a read receipt.
        main.emit([.reset(values: [item("$root", replies: 0)])])
        #expect(await eventually { service.messages.first?.replyCount == 0 })
        #expect(service.threadRepliesLine == 3)
    }

    @Test("Opened by a jump that showed no count, the line follows its root's count and goes with it")
    func jumpShowsNoCount() async throws {
        let main = try #require(await opened(root: item("$root", replies: 4), showingCount: false))
        #expect(service.threadRepliesLine == 4)
        main.emit([.reset(values: [item("$root")])])
        #expect(await eventually { service.messages.first?.replyCount == nil })
        #expect(service.threadRepliesLine == nil)
    }

    @Test("A closed thread pane counts nothing as its conversation changes")
    func closedCountsNothing() async throws {
        let main = try #require(await opened(root: item("$root", replies: 3)))
        service.closeThread()
        main.emit([.reset(values: [item("$root", replies: 6)])])
        #expect(await eventually { service.messages.first?.replyCount == 6 })
        #expect(service.threadRepliesLine == nil)
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

    /// Opens the thread of `root`, which the channel holds, from its replies link or, without `showingCount`, from a
    /// jump that showed no count; the thread's first page is held.
    private func opened(root: FakeTimelineItem, thread: [FakeTimelineItem]? = nil, showingCount: Bool = true) async
        -> FakeLiveTimeline?
    {
        room.threadItems = thread ?? [item("$reply")]
        await service.selectRoom(room.id())
        guard let main = room.timelines.all.first else { return nil }
        main.emit([.reset(values: [root])])
        guard await eventually({ service.messages.first?.eventID == "$root" }), let opener = service.messages.first
        else { return nil }
        room.pageGate.arm()
        try? await service.loadThread(opener, openedWith: showingCount ? opener.replyCount : nil)
        await drainMainActor()
        return main
    }
}
