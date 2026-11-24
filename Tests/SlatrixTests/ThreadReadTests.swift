import Foundation
import Testing

@testable import Slatrix

struct ThreadReadPolicyTests {
    private static let identity = ThreadReadIdentity(
        accountID: "@reader:example.org", sessionID: UUID(), roomID: "!read:example.org", timelineID: UUID(),
        rootID: "$root", threadSelectionID: UUID(), presentationID: UUID())
    private static let visible = ThreadReadContext(
        identity: identity, eventID: "$reply", isPresented: true, isReady: true, isAtBottom: true,
        isWindowActive: true, isWindowVisible: true, isWindowUnoccluded: true)

    // capability: thread.read-state
    @Test("The latest reply of a ready thread scrolled to the bottom of a visible window is read")
    func visibleBottomIsRead() {
        #expect(
            ThreadReadPolicy.target(Self.visible) == ThreadReadReceiptTarget(identity: Self.identity, eventID: "$reply")
        )
    }

    enum Hidden: String, CaseIterable, CustomTestStringConvertible {
        case paneClosed, stillLoading, scrolledUp, appInactive, windowHidden, windowOccluded, sheetOpen
        case markedUnread, noReadyThread, localEcho, noEvent, covered
        var testDescription: String { rawValue }
        func apply(to context: inout ThreadReadContext) {
            switch self {
            case .paneClosed: context.isPresented = false
            case .stillLoading: context.isReady = false
            case .scrolledUp: context.isAtBottom = false
            case .appInactive: context.isWindowActive = false
            case .windowHidden: context.isWindowVisible = false
            case .windowOccluded: context.isWindowUnoccluded = false
            case .sheetOpen: context.hasModal = true
            case .markedUnread: context.manualUnreadHeld = true
            case .noReadyThread: context.identity = nil
            case .localEcho: context.eventID = "transaction"
            case .noEvent: context.eventID = nil
            case .covered: context.isCovered = true
            }
        }
    }

    @Test("A thread the user cannot actually see is not marked read", arguments: Hidden.allCases)
    func hiddenThreadIsNotRead(reason: Hidden) {
        var context = Self.visible
        reason.apply(to: &context)
        #expect(ThreadReadPolicy.target(context) == nil)
    }
}

/// The window's Mark unread hold, which the read policy asks before each write.
@MainActor private final class Reader {
    var hold = ReadStateHold()
}

@MainActor
struct ThreadReadTests {
    /// A loaded thread on `$root` whose latest reply is `$reply`, in a room the user has joined.
    private func fixture() -> ActionFixture {
        let f = ActionFixture()
        f.service.user = ChatUser(id: "@reader:example.org", name: "Reader")
        f.service.messages = [f.message(f.rootID)]
        f.service.threadMessages = [f.message(f.rootID), f.message("$reply", inThread: true)]
        f.service.configureThreadReadForChecks(
            client: f.client, main: f.main, thread: f.thread, rootID: f.rootID, sessionID: f.session,
            selectionID: f.selection, threadID: f.threadLoad, ready: true)
        return f
    }
    private func target(_ f: ActionFixture) throws -> ThreadReadReceiptTarget {
        ThreadReadReceiptTarget(identity: try #require(f.service.threadReadIdentity), eventID: "$reply")
    }

    // capability: activity.badge
    @Test("A reply to an open thread counts in Activity until the reader sees it")
    func openThreadIsNotOpenedReply() {
        let f = fixture()
        f.service.activity.record(
            ActivityItem(
                id: "reply", roomID: f.roomID, eventID: "$late", roomName: "Actions", senderID: "@alice:example.org",
                senderName: "Alice", body: "Reply", timestamp: Date(), hasMention: false, threadRootID: f.rootID,
                kind: .message))
        #expect(ActivityBadge.count(rooms: [], items: f.service.activity.items) == 1)
    }

    @Test("A thread pane's report counts only for the thread ready to read, not one made before it was or for another")
    func reportBelongsToItsThread() throws {
        let f = fixture()
        let identity = try #require(f.service.threadReadIdentity)
        let newest = PaneReport(newestInView: "$reply", laidOut: "$reply")
        f.service.record(newest, thread: nil)
        #expect(f.service.shownThreadReport == nil)
        let reopened = ThreadReadIdentity(
            accountID: identity.accountID, sessionID: identity.sessionID, roomID: identity.roomID,
            timelineID: identity.timelineID, rootID: identity.rootID, threadSelectionID: identity.threadSelectionID,
            presentationID: UUID())
        f.service.record(newest, thread: identity)
        #expect(f.service.shownThreadReport == newest)
        // Late, from a pane on the same thread opened again.
        f.service.record(PaneReport(), thread: reopened)
        #expect(f.service.shownThreadReport == newest)
    }

    // capability: thread.open
    @Test("Opening a thread shows what is cached at once, and makes it readable only once its first page has loaded")
    func readyAfterInitialPage() async throws {
        let f = fixture()
        let root = f.message(f.rootID)
        f.thread.paginationGate.arm()
        defer { f.thread.paginationGate.release() }
        let opened = Recorder<Bool>()
        // Offline, the first page waits for the network indefinitely.
        let loading = Task {
            try await f.service.loadThread(root)
            opened.append(true)
        }
        #expect(await eventually { !opened.all.isEmpty })
        #expect(await eventually { f.thread.paginationGate.isWaiting })
        #expect(f.service.threadMessages == [root] && f.service.threadReadIdentity == nil)
        f.thread.paginationGate.release()
        try await loading.value
        #expect(await eventually { f.service.threadReadIdentity != nil })
        #expect(f.service.hasMoreThreadHistory)
        #expect(f.room.configurations.all.map(\.focus) == [.thread(rootEventId: f.rootID)])
    }

    @Test("A thread whose first page failed stays unread until a retry loads it, and sends no receipt")
    func failedFirstPageStaysUnready() async throws {
        let f = fixture()
        let root = f.message(f.rootID)
        f.thread.failsPagination = true
        try await f.service.loadThread(root)
        await #expect(throws: MatrixServiceError.self) { try await f.service.loadMoreThread(rootID: f.rootID) }
        #expect(f.service.threadReadIdentity == nil && f.service.threadMessages == [root])
        f.thread.failsPagination = false
        _ = try await f.service.loadMoreThread(rootID: f.rootID)
        #expect(f.service.threadReadIdentity != nil)
        #expect(f.thread.writes.all.isEmpty && f.main.writes.all.isEmpty)
    }

    @Test("A thread opened ahead of a click whose first page failed stays unread until a retry loads it")
    func failedPreparedPageStaysUnready() async throws {
        let f = ActionFixture(threadReady: false)
        f.service.user = ChatUser(id: "@reader:example.org", name: "Reader")
        let root = f.message(f.rootID)
        f.service.messages = [root]
        f.thread.failsPagination = true
        f.service.prepareThread(root)
        try await f.service.loadThread(root)
        f.service.setMessageActionThread(rootID: f.rootID)
        #expect(f.service.threadReadIdentity == nil)
        f.thread.failsPagination = false
        _ = try await f.service.loadMoreThread(rootID: f.rootID)
        #expect(f.service.threadReadIdentity != nil)
    }

    // capability: thread.read-state
    @Test("Reading a thread sends one read receipt on the thread timeline and nothing else")
    func sendsThreadReceiptOnce() async throws {
        let f = fixture()
        let target = try target(f)
        try await f.service.markVisibleThreadRead(target, isVisible: { true })
        try await f.service.markVisibleThreadRead(target, isVisible: { true })
        #expect(f.thread.writes.all == ["mark-read"])
        #expect(f.main.writes.all.isEmpty)
    }

    enum Staleness: String, CaseIterable, CustomTestStringConvertible {
        case session, threadReopened, notReady, newReply, undecryptable, left
        var testDescription: String { rawValue }
    }

    @Test("A thread receipt captured before its thread changed sends nothing", arguments: Staleness.allCases)
    func staleReceiptSendsNothing(change: Staleness) async throws {
        let f = fixture()
        let target = try target(f)
        switch change {
        case .session:
            f.session = UUID()
            f.configure()
        case .threadReopened: f.apply(.threadReopened)
        case .left: f.apply(.left)
        case .notReady:
            f.service.configureThreadReadForChecks(
                client: f.client, main: f.main, thread: f.thread, rootID: f.rootID, sessionID: f.session,
                selectionID: f.selection, threadID: f.threadLoad, ready: false)
        case .newReply: f.service.threadMessages.append(f.message("$unseen", inThread: true))
        case .undecryptable: f.service.threadMessages[1].kind = "m.room.encrypted"
        }
        await #expect(throws: CancellationError.self) {
            try await f.service.markVisibleThreadRead(target, isVisible: { true })
        }
        #expect(f.thread.writes.all.isEmpty)
    }

    @Test("A thread that stops being visible while its receipt waits behind another read sends nothing")
    func visibilityIsRecheckedAfterQueueing() async throws {
        let f = fixture()
        f.service.messages = [f.message(f.rootID)]
        let mainRead = ReadReceiptTarget(
            accountID: "@reader:example.org", sessionGeneration: f.session, timelineGeneration: f.selection,
            roomID: f.roomID, eventID: f.rootID)
        f.main.gate.arm()
        let blocking = Task { try await f.service.markVisibleRead(mainRead, isCurrent: { true }) }
        #expect(await eventually { f.main.gate.isWaiting })
        var asked = false
        var visible = true
        let target = try target(f)
        let queued = Task {
            try await f.service.markVisibleThreadRead(target) {
                asked = true
                return visible
            }
        }
        // The first visibility check has passed, so the receipt is now queued behind the main read.
        #expect(await eventually { asked })
        visible = false
        f.main.gate.release()
        try await blocking.value
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(f.thread.writes.all.isEmpty)
    }

    /// Reads the conversation, or the thread, retrying on `delays` while `isCurrent` holds.
    private func read(
        _ f: ActionFixture, inThread: Bool, delays: [Duration], isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        if inThread {
            try await f.service.markVisibleThreadRead(try target(f), retries: delays, isVisible: isCurrent)
        } else {
            try await f.service.markVisibleRead(
                ReadReceiptTarget(
                    accountID: "@reader:example.org", sessionGeneration: f.session, timelineGeneration: f.selection,
                    roomID: f.roomID, eventID: f.rootID), retries: delays, isCurrent: isCurrent)
        }
    }

    // capability: conversation.read
    @Test(
        "A receipt the server turned down goes again after each delay until one goes through", arguments: [false, true])
    func failedReceiptIsRetried(inThread: Bool) async throws {
        let f = fixture()
        let timeline = inThread ? f.thread : f.main
        timeline.failsNextWrites = 3
        try await read(f, inThread: inThread, delays: [.zero, .zero, .zero], isCurrent: { true })
        let fullyRead = inThread ? [] : ["fully:\(f.rootID)"]
        #expect(timeline.writes.all == Array(repeating: "mark-read", count: 4) + fullyRead)
    }

    @Test("A refused receipt is not sent again once the read policy no longer sends it", arguments: [false, true])
    func retryStopsWhenNoLongerCurrent(inThread: Bool) async throws {
        let f = fixture()
        let timeline = inThread ? f.thread : f.main
        timeline.failsNextWrites = 3
        var asked = 0
        await #expect(throws: CancellationError.self) {
            try await read(f, inThread: inThread, delays: [.zero, .zero, .zero]) {
                asked += 1
                return timeline.writes.all.isEmpty
            }
        }
        #expect(asked > 1 && timeline.writes.all == ["mark-read"])
    }

    @Test("Mark unread while a refused receipt goes again stops the writes after the one in flight")
    func markUnreadDuringRetry() async throws {
        let f = fixture()
        let target = ReadReceiptTarget(
            accountID: "@reader:example.org", sessionGeneration: f.session, timelineGeneration: f.selection,
            roomID: f.roomID, eventID: f.rootID)
        let context = ReadStateContext(
            accountID: target.accountID, sessionGeneration: f.session, timelineGeneration: f.selection,
            roomID: f.roomID, selectedRoomID: f.roomID, latestVisibleEventID: f.rootID, isJoined: true,
            isMainTimeline: true, isLiveTimeline: true, isAtBottom: true, isWindowActive: true, isWindowVisible: true,
            isWindowUnoccluded: true)
        let reader = Reader()
        f.main.failsNextWrites = 1
        f.main.gate.arm()
        let reading = Task {
            try await f.service.markVisibleRead(target, retries: [.zero]) {
                ReadStatePolicy.isCurrent(target, in: context, hold: reader.hold)
            }
        }
        #expect(await eventually { f.main.gate.isWaiting })
        // The first attempt fails; the retry's first write waits.
        f.main.gate.release()
        f.main.gate.arm()
        #expect(await eventually { f.main.gate.isWaiting && f.main.writes.all.count == 2 })
        reader.hold.markUnread(context)
        f.main.gate.release()
        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(f.main.writes.all == ["mark-read", "mark-read"])
    }

    @Test("A thread closed and opened again has no report until its pane reports again")
    func reopenedThreadHasNoReport() throws {
        let f = fixture()
        let report = PaneReport(newestInView: "$reply", laidOut: "$reply")
        f.service.record(report, thread: try #require(f.service.threadReadIdentity))
        #expect(f.service.shownThreadReport == report)
        f.apply(.threadReopened)
        #expect(f.service.threadReadIdentity != nil)
        #expect(f.service.shownThreadReport == nil)
    }

    @Test("A receipt in flight when the thread is reopened finishes once and is not credited to the new pane")
    func inFlightReceiptAfterReopen() async throws {
        let f = fixture()
        let target = try target(f)
        f.thread.gate.arm()
        let reading = Task { try await f.service.markVisibleThreadRead(target, isVisible: { true }) }
        #expect(await eventually { f.thread.gate.isWaiting })
        f.apply(.threadReopened)
        f.thread.gate.release()
        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(f.thread.writes.all == ["mark-read"])
    }

    // capability: conversation.read
    @Test("A reaction or unread count bump in an already-open conversation re-sends a read receipt without looping")
    func reactionOrUnreadIncreaseReacknowledgesOpenConversation() async throws {
        let f = fixture()
        let target = ReadReceiptTarget(
            accountID: "@reader:example.org", sessionGeneration: f.session, timelineGeneration: f.selection,
            roomID: f.roomID, eventID: f.rootID)
        try await f.service.markVisibleRead(target, retries: []) { true }
        #expect(f.main.writes.all == ["mark-read", "fully:\(f.rootID)"])

        // A second call with nothing new stays suppressed.
        let beforeToken = f.service.unreadAckToken
        try await f.service.markVisibleRead(target, retries: []) { true }
        #expect(f.main.writes.all.count == 2 && f.service.unreadAckToken == beforeToken)

        // Adding your own reaction never triggers a new receipt.
        var ownReaction = f.service.messages[0]
        ownReaction.reactions = [MessageReaction(key: "👍", count: 1, mine: true)]
        f.service.messages = [ownReaction]
        #expect(f.service.unreadAckToken == beforeToken)

        // Someone else's reaction on the latest (already-read) message bumps unreadAckToken and allows a new receipt.
        var otherReaction = ownReaction
        otherReaction.reactions = [MessageReaction(key: "👍", count: 2, mine: true)]
        f.service.messages = [otherReaction]
        #expect(f.service.unreadAckToken == beforeToken + 1)
        try await f.service.markVisibleRead(target, retries: []) { true }
        #expect(f.main.writes.all == ["mark-read", "fully:\(f.rootID)", "mark-read", "fully:\(f.rootID)"])

        // An unread count increase on the open room (e.g., reaction/edit on an earlier message) also re-arms once.
        let tokenBeforeRoom = f.service.unreadAckToken
        var room = ChatRoom(id: f.roomID, name: "Actions")
        f.service.rooms = [room]
        #expect(f.service.unreadAckToken == tokenBeforeRoom)
        room.unread = 1
        f.service.rooms = [room]
        #expect(f.service.unreadAckToken == tokenBeforeRoom + 1)
        // Clearing unread back to 0 must never bump the token again (no receipt loop).
        room.unread = 0
        f.service.rooms = [room]
        #expect(f.service.unreadAckToken == tokenBeforeRoom + 1)
    }

    // capability: thread.read-state
    @Test("A reaction from someone else in an already-open thread re-sends a thread read receipt")
    func reactionInOpenThreadReacknowledgesThread() async throws {
        let f = fixture()
        let target = try target(f)
        try await f.service.markVisibleThreadRead(target, retries: []) { true }
        #expect(f.thread.writes.all == ["mark-read"])

        let beforeToken = f.service.threadAckToken
        var reacted = f.service.threadMessages[1]
        reacted.reactions = [MessageReaction(key: "🔥", count: 1, mine: false)]
        f.service.threadMessages = [f.service.threadMessages[0], reacted]
        #expect(f.service.threadAckToken == beforeToken + 1)

        try await f.service.markVisibleThreadRead(target, retries: []) { true }
        #expect(f.thread.writes.all == ["mark-read", "mark-read"])
    }

    // capability: activity.badge
    @Test(
        "Reading a thread to the bottom marks older paginated-out Activity replies opened without consuming newer unrendered ones"
    )
    func markVisibleThreadReadClearsAllThreadActivityItems() async throws {
        let f = fixture()
        f.service.threadMessages[1].timestamp = Date(timeIntervalSince1970: 1_000)
        f.service.activity.record(
            ActivityItem(
                id: "older-reply", roomID: f.roomID, eventID: "$paginated-out", roomName: "Actions",
                senderID: "@alice:example.org", senderName: "Alice", body: "Older reply",
                timestamp: Date(timeIntervalSince1970: 500), hasMention: false, threadRootID: f.rootID, kind: .message))
        f.service.activity.record(
            ActivityItem(
                id: "newer-reply", roomID: f.roomID, eventID: "$not-in-timeline-yet", roomName: "Actions",
                senderID: "@alice:example.org", senderName: "Alice", body: "Newer reply",
                timestamp: Date(timeIntervalSince1970: 2_000), hasMention: false, threadRootID: f.rootID, kind: .message
            ))
        f.service.activity.record(
            ActivityItem(
                id: "other-thread-reply", roomID: f.roomID, eventID: "$other-reply", roomName: "Actions",
                senderID: "@alice:example.org", senderName: "Alice", body: "Other thread",
                timestamp: Date(timeIntervalSince1970: 500), hasMention: false, threadRootID: "$other-root",
                kind: .message))
        #expect(ActivityBadge.count(rooms: [], items: f.service.activity.items) == 3)

        try await f.service.markVisibleThreadRead(try target(f), retries: []) { true }

        #expect(f.service.activity.items.first { $0.id == "older-reply" }?.opened == true)
        #expect(f.service.activity.items.first { $0.id == "newer-reply" }?.opened == false)
        #expect(f.service.activity.items.first { $0.id == "other-thread-reply" }?.opened == false)
        #expect(ActivityBadge.count(rooms: [], items: f.service.activity.items) == 2)
    }
}
