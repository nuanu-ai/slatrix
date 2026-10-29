import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private let room = ChatRoom(id: "!one:example.org", name: "One")
private let redacted = TimelineItemContent.msgLike(
    content: MsgLikeContent(kind: .redacted, inReplyTo: nil, threadRoot: nil, threadSummary: nil))

private func thread(latest: UInt64? = 5_000, replies: UInt32 = 9) -> ThreadListItem {
    ThreadListItem(
        rootEvent: threadEvent("$root", content: redacted),
        latestEvent: latest.map { threadEvent("$reply", timestamp: $0, content: redacted) }, numReplies: replies)
}

struct ThreadFeedMappingTests {
    // capability: threads.feed
    @Test("A thread appears once, with the SDK's reply count, ordered by its latest reply")
    func projectsThread() throws {
        let projected = ThreadFeedMapping.project([thread(), thread()], room: room)
        let item = try #require(projected.first)
        #expect(projected.count == 1 && item.replyCount == 9 && item.root.replyCount == 9)
        #expect(item.latest?.id == "$reply" && item.lastActivityAt == Date(timeIntervalSince1970: 5))
    }

    @Test("A deleted thread root keeps none of its original text")
    func redactedRoot() throws {
        let item = try #require(ThreadFeedMapping.project([thread()], room: room).first)
        #expect(item.root.isRedacted && item.root.body == "This message was deleted")
    }

    @Test("An older page of the same thread cannot replace its newer summary")
    func olderDuplicateIgnored() {
        let projected = ThreadFeedMapping.project([thread(), thread(latest: nil, replies: 1)], room: room)
        #expect(projected.map(\.replyCount) == [9])
    }

    // capability: home.private-channel-icon
    @Test("A private channel's thread carries its privacy, for its lock")
    func privateChannel() {
        var channel = room
        channel.isPrivate = true
        #expect(ThreadFeedMapping.project([thread()], room: channel).first?.isPrivate == true)
        #expect(ThreadFeedMapping.project([thread()], room: room).first?.isPrivate == false)
    }

    @Test("The same event IDs in two rooms are two threads")
    func roomsKeepThreadsApart() {
        let first = ThreadFeedMapping.project([thread()], room: room)
        let second = ThreadFeedMapping.project([thread()], room: ChatRoom(id: "!two:example.org", name: "Two"))
        #expect(first[0].id != second[0].id)
    }

    @Test("DMs show in every workspace, unlinked channels only outside one, and invites nowhere")
    func scope() {
        var dm = room
        dm.isDirect = true
        #expect(ThreadFeedMapping.isInScope(dm, workspaceID: "!workspace:example.org"))
        #expect(!ThreadFeedMapping.isInScope(room, workspaceID: "!workspace:example.org"))
        #expect(ThreadFeedMapping.isInScope(room, workspaceID: nil))
        dm.membership = "invite"
        #expect(!ThreadFeedMapping.isInScope(dm, workspaceID: nil))
    }

    @Test("A thread message the SDK can't show yet is marked unavailable")
    func unavailableMessage() {
        var event = threadEvent("$root")
        event.content = nil
        #expect(ThreadFeedMapping.message(event, roomID: room.id).kind == "unavailable")
    }
}

private final class NotificationEvent: TimelineEvent, @unchecked Sendable {
    var sender = "@alice:example.org"
    var value: TimelineEventContent?
    override func eventId() -> String { "$notification" }
    override func senderId() -> String { sender }
    override func timestamp() -> UInt64 { 1_000 }
    override func threadRootEventId() -> String? { "$thread" }
    override func content() throws -> TimelineEventContent {
        value
            ?? .messageLike(
                content: .roomMessage(
                    messageType: .text(
                        content: TextMessageContent(
                            body: "secret",
                            formatted: FormattedBody(format: .html, body: "<span data-mx-spoiler>secret</span>"))),
                    inReplyToEventId: nil))
    }
}

private func notification(_ event: NotificationEvent, actions: [Action]? = nil) -> NotificationItem {
    NotificationItem(
        event: .timeline(event: event), rawEvent: "",
        senderInfo: NotificationSenderInfo(displayName: "Alice", avatarUrl: nil, isNameAmbiguous: false),
        roomInfo: NotificationRoomInfo(
            displayName: "One", avatarUrl: nil, canonicalAlias: nil, topic: nil, joinRule: nil, joinedMembersCount: 1,
            activeServiceMembersCount: 0, serviceMembers: [], isEncrypted: true, isDirect: false, isSpace: false,
            isDm: false), isNoisy: false, hasMention: true, threadId: nil, actions: actions)
}

@MainActor
struct ActivityTests {
    private let activity = ActivityService()
    private let me = "@me:example.org"

    @Test("Activity previews hide formatted spoilers, keep unknown formats literal, and are bounded")
    func previewBody() {
        #expect(
            ActivityService.previewBody(
                "private", formatted: FormattedBody(format: .html, body: "<span DATA-MX-SPOILER>p</span>"))
                == "[Spoiler hidden]")
        #expect(
            ActivityService.previewBody(
                "Literal text", formatted: FormattedBody(format: .unknown(format: "example"), body: "data-mx-spoiler"))
                == "Literal text")
        #expect(ActivityService.previewBody(String(repeating: "x", count: 5_000), formatted: nil).count < 5_000)
    }

    // capability: activity.feed
    @Test("A mention notification shows its sender and thread with spoilers hidden, once")
    func mentionNotification() {
        let event = NotificationEvent(noHandle: .init())
        let item = activity.receive(notification(event), roomID: room.id, ownUserID: me)
        #expect(item?.body == "[Spoiler hidden]" && item?.senderName == "Alice" && item?.threadRootID == "$thread")
        #expect(activity.mentions.count == 1)
        #expect(activity.receive(notification(event), roomID: room.id, ownUserID: me) == nil)
        #expect(activity.items.count == 1)
    }

    enum Ignored: CaseIterable { case own, roomState, verification }

    @Test("My own messages, room state and verification signalling stay out of Activity", arguments: Ignored.allCases)
    func ignored(kind: Ignored) {
        let event = NotificationEvent(noHandle: .init())
        switch kind {
        case .own: event.sender = me
        case .roomState: event.value = .state(content: .roomTopic(topic: "Updated topic"))
        case .verification: event.value = .messageLike(content: .keyVerificationStart)
        }
        #expect(activity.receive(notification(event), roomID: room.id, ownUserID: me) == nil)
        #expect(activity.items.isEmpty)
    }

    @Test(
        "A native alert is allowed unless the SDK's actions omit notify",
        arguments: [([], false), ([.notify], true), (nil, true)] as [([Action]?, Bool)])
    func nativeAlert(actions: [Action]?, allowed: Bool) {
        let item = activity.receive(
            notification(NotificationEvent(noHandle: .init()), actions: actions), roomID: room.id, ownUserID: me)
        #expect(item?.allowsNativeNotification == allowed)
    }

    @Test("A replayed invitation keeps its identity and first received time")
    func replayedInvitation() {
        var invite = notification(NotificationEvent(noHandle: .init()))
        invite.event = .invite(sender: "@alice:example.org")
        let first = activity.receive(
            invite, roomID: "!invite:example.org", ownUserID: me, receivedAt: Date(timeIntervalSince1970: 2))
        let repeated = activity.receive(
            invite, roomID: "!invite:example.org", ownUserID: me, receivedAt: Date(timeIntervalSince1970: 3))
        #expect(first?.eventID == nil && repeated == nil)
        #expect(activity.items.first?.timestamp == Date(timeIntervalSince1970: 2))
    }

    // capability: activity.feed
    @Test("Activity keeps the latest items first up to its limit, and clearing empties it")
    func boundedAndCleared() {
        for index in 0...ActivityService.maximumItems {
            activity.record(
                ActivityItem(
                    id: "item-\(index)", roomID: room.id, eventID: "$\(index)", roomName: room.name,
                    senderID: "@alice:example.org", senderName: "Alice", body: "Message",
                    timestamp: Date(timeIntervalSince1970: Double(index + 2)), hasMention: false, threadRootID: nil,
                    kind: .message))
        }
        #expect(activity.items.count == ActivityService.maximumItems)
        #expect(activity.items.first?.eventID == "$\(ActivityService.maximumItems)")
        activity.clear()
        #expect(activity.items.isEmpty && activity.mentions.isEmpty)
    }
}

@MainActor
struct ThreadRoutingTests {
    private let service = MatrixService()
    private let root = ChatMessage(
        id: "$root", roomID: room.id, senderID: "@alice:example.org", senderName: "Alice", body: "Root",
        timestamp: .distantPast)

    @Test("Opening a thread from another room is refused before the open thread is cleared")
    func crossRoomThread() async {
        service.selectedRoomID = "!selected:example.org"
        service.threadMessages = [root]
        await #expect(throws: (any Error).self) { try await service.loadThread(root) }
        #expect(service.threadMessages == [root])
    }

    @Test("A thread that isn't open cannot page in the room timeline")
    func unopenedThreadPaging() async {
        service.threadMessages = [root]
        await #expect(throws: (any Error).self) { _ = try await service.loadMoreThread(rootID: "$unopened") }
        #expect(service.threadMessages == [root])
    }
}

@MainActor
struct ThreadFeedDiscoveryTests {
    private let feed = ThreadFeedService()
    private let sdkRoom = FakeThreadRoom()
    private let rooms = (0..<18).map { ChatRoom(id: "!room\($0):example.org", name: "Room \($0)") }

    // capability: threads.feed
    @Test("Opening Threads checks the first page of every room in scope by itself")
    func discoversAllRooms() async {
        await feed.open(client: FakeThreadClient(sdkRoom), rooms: rooms, workspaceID: nil) { _ in }
        #expect(feed.checkedRoomCount == rooms.count && !feed.canCheckMore && !feed.isLoading)
    }

    @Test("Closing Threads before discovery starts sends no page requests")
    func closeStopsDiscovery() async {
        await feed.open(client: FakeThreadClient(sdkRoom), rooms: rooms, workspaceID: nil) { _ in feed.close() }
        #expect(!feed.isActive && feed.items.isEmpty && sdkRoom.threads.pages.all.isEmpty)
    }

    @Test("Marking the feed unavailable and closing it clears what it published")
    func closeClears() {
        feed.unavailable("Unavailable")
        feed.close()
        #expect(feed.items.isEmpty && feed.roomStates.isEmpty && !feed.isActive && feed.errorMessage == nil)
    }
}
