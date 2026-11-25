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
        #expect(item.root.isRedacted && item.root.body == "This message was deleted.")
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

    // capability: threads.feed
    @Test("A thread is unread only when someone else replied after your threaded and unthreaded read receipts")
    func unreadStateFromReceipts() throws {
        let me = "@me:example.org"
        let reply = threadEvent("$reply", timestamp: 5_000, sender: "@alice:example.org", isOwn: false)
        let ownReply = threadEvent("$own", timestamp: 5_000, sender: me, isOwn: true)
        let ownBySender = threadEvent("$own-sender", timestamp: 5_000, sender: me, isOwn: false)
        #expect(
            ThreadFeedMapping.isUnread(
                latest: reply, ownUserID: me, threadReceipt: nil, unthreadedReceipt: nil))
        #expect(
            !ThreadFeedMapping.isUnread(
                latest: nil, ownUserID: me, threadReceipt: nil, unthreadedReceipt: nil))
        #expect(
            !ThreadFeedMapping.isUnread(
                latest: ownReply, ownUserID: me, threadReceipt: nil, unthreadedReceipt: nil))
        #expect(
            !ThreadFeedMapping.isUnread(
                latest: ownBySender, ownUserID: me, threadReceipt: nil, unthreadedReceipt: nil))
        // Older threaded receipt still leaves the newer reply unread.
        let olderThread = UserReceipt(eventId: "$earlier", receipt: Receipt(timestamp: 4_000))
        #expect(
            ThreadFeedMapping.isUnread(
                latest: reply, ownUserID: me, threadReceipt: olderThread, unthreadedReceipt: nil))
        // Matching event ID or >= timestamp on either threaded or unthreaded receipt clears unread.
        let exactThread = UserReceipt(eventId: "$reply", receipt: Receipt(timestamp: nil))
        #expect(
            !ThreadFeedMapping.isUnread(
                latest: reply, ownUserID: me, threadReceipt: exactThread, unthreadedReceipt: nil))
        let newerThread = UserReceipt(eventId: "$later", receipt: Receipt(timestamp: 5_000))
        #expect(
            !ThreadFeedMapping.isUnread(
                latest: reply, ownUserID: me, threadReceipt: newerThread, unthreadedReceipt: nil))
        let newerUnthreaded = UserReceipt(eventId: "$room-latest", receipt: Receipt(timestamp: 6_000))
        #expect(
            !ThreadFeedMapping.isUnread(
                latest: reply, ownUserID: me, threadReceipt: olderThread, unthreadedReceipt: newerUnthreaded))
        let olderUnthreaded = UserReceipt(eventId: "$room-old", receipt: Receipt(timestamp: 3_000))
        #expect(
            ThreadFeedMapping.isUnread(
                latest: reply, ownUserID: me, threadReceipt: nil, unthreadedReceipt: olderUnthreaded))
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

    // capability: people.names
    @Test("A notification names the people it mentions, and finds whom to look up")
    func namedMentions() {
        let event = NotificationEvent(noHandle: .init())
        event.value = .messageLike(
            content: .roomMessage(
                messageType: .text(
                    content: TextMessageContent(body: "@sam:example.org and @kai:example.org, look", formatted: nil)),
                inReplyToEventId: nil))
        #expect(ActivityService.mentionedIDs(notification(event)) == ["@sam:example.org", "@kai:example.org"])
        let item = activity.receive(
            notification(event), roomID: room.id, ownUserID: me, names: ["@sam:example.org": "Sam Okafor"])
        #expect(item?.body == "@Sam Okafor and @kai, look")
    }

    @Test(
        "Only a reply loses the quote it opens with; another message keeps a quote that starts it",
        arguments: [
            (nil, "> <config>old value</config>\n\nUse this value."), ("$earlier", "My reply"),
        ])
    func replyFallback(inReplyTo: String?, shown: String) {
        let event = NotificationEvent(noHandle: .init())
        let body = inReplyTo == nil ? shown : "> <@bob:example.org> Earlier\n\nMy reply"
        event.value = .messageLike(
            content: .roomMessage(
                messageType: .text(content: TextMessageContent(body: body, formatted: nil)),
                inReplyToEventId: inReplyTo))
        #expect(activity.receive(notification(event), roomID: room.id, ownUserID: me)?.body == shown)
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

    // capability: activity.feed
    @Test("A reaction notification appears in Activity targeting the reacted message without inflating the badge count")
    func reactionNotificationShowsInActivity() throws {
        let event = NotificationEvent(noHandle: .init())
        event.value = .messageLike(content: .reactionContent(relatedEventId: "$mine"))
        var raw = notification(event)
        raw.hasMention = false
        raw.threadId = nil
        raw.rawEvent = #"{"content":{"m.relates_to":{"rel_type":"m.annotation","event_id":"$mine","key":"👍"}}}"#
        let item = try #require(activity.receive(raw, roomID: room.id, ownUserID: me))
        #expect(item.kind == .reaction)
        #expect(item.eventID == "$mine")
        #expect(item.body == "Reacted 👍")
        #expect(ActivityBadge.count(rooms: [], items: activity.items) == 0)
        var unreadRoom = room
        unreadRoom.unread = 1
        #expect(ActivityBadge.isUnread(item, room: unreadRoom))
        unreadRoom.unread = 0
        #expect(!ActivityBadge.isUnread(item, room: unreadRoom))
    }
}

@MainActor
struct ThreadRoutingTests {
    private let service = MatrixService.scratch()
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

    @Test("Older replies asked for while the thread is still opening are left to its opening, with no error")
    func pagingWhileOpening() async throws {
        service.threadMessages = [root]
        _ = try await service.loadMoreThread(rootID: root.eventID)
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

    @Test("Threads shows its list once every room's first page is in, so threads never arrive and move on screen")
    func showsOnce() async {
        let sdkRooms = Dictionary(
            uniqueKeysWithValues: rooms.map { room in
                let id = "$root-\(room.id)"
                return (
                    room.id,
                    FakeThreadRoom(
                        threads: FakeThreadList([
                            ThreadListItem(rootEvent: threadEvent(id), latestEvent: nil, numReplies: 1)
                        ]), timelines: [id: FakeEventTimeline(textEvent(id, body: "Current"))])
                )
            })
        var shownWhilePaging: [Int] = []
        await feed.open(client: FakeThreadClient(sdkRoom, rooms: sdkRooms), rooms: rooms, workspaceID: nil) { _ in
            shownWhilePaging.append(feed.items.count)
        }
        #expect(shownWhilePaging.allSatisfy { $0 == 0 } && feed.items.count == rooms.count)
    }

    @Test("Threads opened again shows what it last showed at once, in its current text, while it checks again")
    func reopensAtOnce() async throws {
        let room = FakeThreadRoom(
            threads: FakeThreadList([ThreadListItem(rootEvent: threadEvent("$root"), latestEvent: nil, numReplies: 1)]),
            timelines: ["$root": FakeEventTimeline(textEvent("$root", body: "Edited successfully", edited: true))])
        let client = FakeThreadClient(room)
        await feed.open(client: client, rooms: [rooms[0]], workspaceID: nil) { _ in }
        feed.close()
        var shownOnReopen: [String] = []
        await feed.open(client: client, rooms: [rooms[0]], workspaceID: nil) { _ in
            if shownOnReopen.isEmpty {
                shownOnReopen = feed.items.map {
                    feed.preview(roomID: $0.roomID, eventID: $0.root.eventID).shown($0.root).body
                }
            }
        }
        #expect(shownOnReopen == ["Edited successfully"])
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

    // capability: threads.feed
    @Test("Threads load unread state from threaded and unthreaded receipts, clear when read, and re-arm on new replies")
    func unreadStateAndReadClearing() async throws {
        let me = "@me:example.org"
        let unreadThread = ThreadListItem(
            rootEvent: threadEvent("$t-unread", timestamp: 1_000),
            latestEvent: threadEvent("$r-unread", timestamp: 5_000), numReplies: 2)
        let readByThread = ThreadListItem(
            rootEvent: threadEvent("$t-thread", timestamp: 1_000),
            latestEvent: threadEvent("$r-thread", timestamp: 5_000), numReplies: 1)
        let readByUnthreaded = ThreadListItem(
            rootEvent: threadEvent("$t-unthreaded", timestamp: 1_000),
            latestEvent: threadEvent("$r-unthreaded", timestamp: 4_000), numReplies: 1)
        let ownLatest = ThreadListItem(
            rootEvent: threadEvent("$t-own", timestamp: 1_000),
            latestEvent: threadEvent("$r-own", timestamp: 6_000, sender: me, isOwn: true), numReplies: 1)
        let list = FakeThreadList([unreadThread, readByThread, readByUnthreaded, ownLatest])
        let fakeRoom = FakeThreadRoom(
            threads: list,
            receipts: [
                .unthreaded: UserReceipt(eventId: "$room", receipt: Receipt(timestamp: 4_500)),
                .thread(threadRootEventId: "$t-thread"): UserReceipt(
                    eventId: "$r-thread", receipt: Receipt(timestamp: nil)),
                .thread(threadRootEventId: "$t-unread"): UserReceipt(
                    eventId: "$r-old", receipt: Receipt(timestamp: 2_000)),
            ])
        let client = FakeThreadClient(fakeRoom)
        await feed.open(client: client, rooms: [rooms[0]], workspaceID: nil, ownUserID: me) { _ in }
        let byRoot = Dictionary(uniqueKeysWithValues: feed.items.map { ($0.root.eventID, $0.isUnread) })
        #expect(byRoot == ["$t-unread": true, "$t-thread": false, "$t-unthreaded": false, "$t-own": false])

        // Reading the thread clears its unread flag immediately and keeps it cleared across close/reopen.
        feed.markThreadRead(roomID: rooms[0].id, rootID: "$t-unread", eventID: "$r-unread")
        #expect(feed.items.first { $0.root.eventID == "$t-unread" }?.isUnread == false)
        feed.close()
        await feed.open(client: client, rooms: [rooms[0]], workspaceID: nil, ownUserID: me) { _ in }
        #expect(feed.items.first { $0.root.eventID == "$t-unread" }?.isUnread == false)

        // A brand-new reply on that thread makes it unread again.
        let updatedUnread = ThreadListItem(
            rootEvent: threadEvent("$t-unread", timestamp: 1_000),
            latestEvent: threadEvent("$r-newer", timestamp: 7_000), numReplies: 3)
        list.emit([updatedUnread, readByThread, readByUnthreaded, ownLatest])
        #expect(await eventually { feed.items.first { $0.root.eventID == "$t-unread" }?.isUnread == true })

        // Marking the room read clears unread threads in that room.
        feed.markRoomRead(roomID: rooms[0].id)
        #expect(feed.items.filter(\.isUnread).map(\.root.eventID) == [])
    }

    // capability: threads.feed
    @Test(
        "Private read receipts and partial cross-device unread decreases clear read threads without rolling back live replies"
    )
    func privateReceiptsCrossDeviceDecreaseAndLiveRace() async throws {
        let me = "@me:example.org"
        let privateRead = ThreadListItem(
            rootEvent: threadEvent("$t-private", timestamp: 1_000),
            latestEvent: threadEvent("$r-private", timestamp: 5_000), numReplies: 1)
        let pending = ThreadListItem(
            rootEvent: threadEvent("$t-pending", timestamp: 1_000),
            latestEvent: threadEvent("$r-a", timestamp: 5_000), numReplies: 1)
        let list = FakeThreadList([privateRead, pending])
        let fakeRoom = FakeThreadRoom(
            threads: list,
            privateReceipts: [
                .thread(threadRootEventId: "$t-private"): UserReceipt(
                    eventId: "$r-private", receipt: Receipt(timestamp: 5_000))
            ])
        let client = FakeThreadClient(fakeRoom)
        var chatRoom = rooms[0]
        chatRoom.unread = 3
        await feed.open(client: client, rooms: [chatRoom], workspaceID: nil, ownUserID: me) { _ in }
        #expect(feed.items.first { $0.root.eventID == "$t-private" }?.isUnread == false)
        #expect(feed.items.first { $0.root.eventID == "$t-pending" }?.isUnread == true)

        // A partial unread count decrease (e.g. phone read one thread while main stays unread) refreshes receipts.
        fakeRoom.receipts = [
            .thread(threadRootEventId: "$t-pending"): UserReceipt(eventId: "$r-a", receipt: Receipt(timestamp: 5_000))
        ]
        chatRoom.unread = 2
        feed.updateRooms([chatRoom])
        #expect(await eventually { feed.items.first { $0.root.eventID == "$t-pending" }?.isUnread == false })

        // Pagination suspended during receipt load must never overwrite a newer live reply emitted meanwhile.
        fakeRoom.receiptGate.arm()
        let paging = Task {
            await feed.open(client: client, rooms: [chatRoom], workspaceID: nil, ownUserID: me) { _ in }
        }
        #expect(await eventually { fakeRoom.receiptGate.isWaiting })
        let liveReply = ThreadListItem(
            rootEvent: threadEvent("$t-pending", timestamp: 1_000),
            latestEvent: threadEvent("$r-b", timestamp: 6_000), numReplies: 2)
        list.emit([privateRead, liveReply])
        await drainMainActor()
        fakeRoom.receiptGate.release()
        await paging.value
        let updated = try #require(feed.items.first { $0.root.eventID == "$t-pending" })
        #expect(updated.latest?.eventID == "$r-b" && updated.isUnread)
    }

    // capability: threads.feed
    @Test("Switching workspaces keeps each workspace's cached threads and updates read state across them")
    func reopensAcrossWorkspacesAtOnce() async throws {
        let me = "@me:example.org"
        var roomA = ChatRoom(id: "!a:example.org", name: "Alpha")
        roomA.spaceIDs = ["!ws-a:example.org"]
        var roomB = ChatRoom(id: "!b:example.org", name: "Beta")
        roomB.spaceIDs = ["!ws-b:example.org"]
        let fakeA = FakeThreadRoom(
            threads: FakeThreadList([
                ThreadListItem(
                    rootEvent: threadEvent("$root-a", timestamp: 1_000),
                    latestEvent: threadEvent("$reply-a", timestamp: 5_000), numReplies: 2)
            ]),
            timelines: [
                "$root-a": FakeEventTimeline(textEvent("$root-a", body: "Alpha root")),
                "$reply-a": FakeEventTimeline(textEvent("$reply-a", body: "Alpha reply")),
            ])
        let fakeB = FakeThreadRoom(
            threads: FakeThreadList([
                ThreadListItem(
                    rootEvent: threadEvent("$root-b", timestamp: 2_000),
                    latestEvent: nil, numReplies: 1)
            ]),
            timelines: ["$root-b": FakeEventTimeline(textEvent("$root-b", body: "Beta root"))])
        let client = FakeThreadClient(sdkRoom, rooms: [roomA.id: fakeA, roomB.id: fakeB])
        await feed.open(client: client, rooms: [roomA, roomB], workspaceID: "!ws-a:example.org", ownUserID: me) { _ in }
        feed.close()
        await feed.open(client: client, rooms: [roomA, roomB], workspaceID: "!ws-b:example.org", ownUserID: me) { _ in }
        feed.close()

        // Marking a thread read in workspace A clears it in workspace A's cached list too.
        feed.markThreadRead(roomID: roomA.id, rootID: "$root-a", eventID: "$reply-a")

        var shownOnReturn: [(String, Bool)] = []
        await feed.open(client: client, rooms: [roomA, roomB], workspaceID: "!ws-a:example.org", ownUserID: me) { _ in
            if shownOnReturn.isEmpty { shownOnReturn = feed.items.map { ($0.root.eventID, $0.isUnread) } }
        }
        #expect(shownOnReturn.count == 1)
        #expect(shownOnReturn.first?.0 == "$root-a")
        #expect(shownOnReturn.first?.1 == false)
    }

    // capability: threads.feed
    @Test("Opening Threads across many rooms updates subscriptions once instead of per small batch")
    func discoversRoomsInOneBatch() async {
        var subscriptionUpdates = 0
        await feed.open(client: FakeThreadClient(sdkRoom), rooms: rooms, workspaceID: nil) { _ in
            subscriptionUpdates += 1
        }
        #expect(subscriptionUpdates == 1)
        #expect(feed.checkedRoomCount == rooms.count)
    }

    // capability: threads.feed
    @Test("Reopening Threads with cached previews does not block on re-opening preview timelines")
    func warmReopenSkipsHydrationBarrier() async throws {
        let fakeRoom = FakeThreadRoom(
            threads: FakeThreadList([
                ThreadListItem(
                    rootEvent: threadEvent("$root", timestamp: 1_000),
                    latestEvent: threadEvent("$reply", timestamp: 2_000), numReplies: 1)
            ]),
            timelines: [
                "$root": FakeEventTimeline(textEvent("$root", body: "Cached root")),
                "$reply": FakeEventTimeline(textEvent("$reply", body: "Cached reply")),
            ])
        let client = FakeThreadClient(fakeRoom)
        await feed.open(client: client, rooms: [rooms[0]], workspaceID: nil) { _ in }
        feed.close()

        fakeRoom.timelineGate.arm()
        var finished = false
        let reopen = Task {
            await feed.open(client: client, rooms: [rooms[0]], workspaceID: nil) { _ in }
            finished = true
        }
        let settled = await eventually(timeout: .seconds(2)) { finished || fakeRoom.timelineGate.isWaiting }
        let blocked = fakeRoom.timelineGate.isWaiting
        fakeRoom.timelineGate.release()
        await reopen.value
        #expect(settled && !blocked)
        #expect(feed.preview(roomID: rooms[0].id, eventID: "$root").state == .ready)
        #expect(feed.preview(roomID: rooms[0].id, eventID: "$reply").state == .ready)
    }

    // capability: threads.feed
    @Test("Preparing Threads restores cached items synchronously and prevents an empty-state flash when cold")
    func prepareRestoresCacheOrMarksDiscovering() async {
        feed.prepare(workspaceID: "!cold:example.org")
        #expect(feed.isDiscovering && feed.items.isEmpty)

        let fakeRoom = FakeThreadRoom(
            threads: FakeThreadList([ThreadListItem(rootEvent: threadEvent("$root"), latestEvent: nil, numReplies: 1)]),
            timelines: ["$root": FakeEventTimeline(textEvent("$root", body: "Ready"))])
        await feed.open(client: FakeThreadClient(fakeRoom), rooms: [rooms[0]], workspaceID: nil) { _ in }
        feed.close()
        #expect(feed.items.isEmpty && !feed.isDiscovering)

        feed.prepare(workspaceID: nil)
        #expect(feed.isDiscovering && feed.items.map(\.root.eventID) == ["$root"])
    }

    // capability: threads.feed
    @Test("Cold open publishes threads when hydration times out instead of blocking on a slow preview")
    func coldOpenRespectsHydrationTimeout() async {
        let fakeRoom = FakeThreadRoom(
            threads: FakeThreadList([ThreadListItem(rootEvent: threadEvent("$slow"), latestEvent: nil, numReplies: 1)]),
            timelines: ["$slow": FakeEventTimeline(textEvent("$slow", body: "Arrived late"))])
        fakeRoom.timelineGate.arm()
        feed.hydrationTimeout = .milliseconds(25)
        await feed.open(client: FakeThreadClient(fakeRoom), rooms: [rooms[0]], workspaceID: nil) { _ in }
        #expect(!feed.isDiscovering && feed.items.map(\.root.eventID) == ["$slow"])
        // Once the slow preview eventually lands in the background, the row updates cleanly.
        fakeRoom.timelineGate.release()
        #expect(await eventually { feed.preview(roomID: rooms[0].id, eventID: "$slow").state == .ready })
    }

    // capability: threads.feed
    @Test("Failed rooms and rooms with older pages can be retried or loaded in batch")
    func retryFailedAndLoadOlderBatch() async {
        let failingList = FakeThreadList([
            ThreadListItem(rootEvent: threadEvent("$recovered"), latestEvent: nil, numReplies: 1)
        ])
        failingList.failPaginate = true
        let pagedList = FakeThreadList([
            ThreadListItem(rootEvent: threadEvent("$page1"), latestEvent: nil, numReplies: 1)
        ])
        pagedList.remainingPages = 2
        let client = FakeThreadClient(
            sdkRoom,
            rooms: [
                rooms[0].id: FakeThreadRoom(threads: failingList),
                rooms[1].id: FakeThreadRoom(threads: pagedList),
            ])
        await feed.open(client: client, rooms: [rooms[0], rooms[1]], workspaceID: nil) { _ in }
        #expect(feed.failedRoomCount == 1)
        #expect(feed.hasOlderThreads)

        failingList.failPaginate = false
        await feed.retryFailed()
        #expect(feed.failedRoomCount == 0 && feed.items.contains { $0.root.eventID == "$recovered" })

        await feed.loadOlder()
        #expect(!feed.hasOlderThreads)
        #expect(pagedList.pages.all.count == 2)
    }
}
