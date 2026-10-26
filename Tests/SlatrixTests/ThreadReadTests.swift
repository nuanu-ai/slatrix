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

    @Test("The latest reply of a ready thread scrolled to the bottom of a visible window is read")
    func visibleBottomIsRead() {
        #expect(
            ThreadReadPolicy.target(Self.visible) == ThreadReadReceiptTarget(identity: Self.identity, eventID: "$reply")
        )
    }

    enum Hidden: String, CaseIterable, CustomTestStringConvertible {
        case paneClosed, stillLoading, scrolledUp, appInactive, windowHidden, windowOccluded, sheetOpen
        case markedUnread, noReadyThread, localEcho, noEvent
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
            }
        }
    }

    @Test("A thread the user cannot actually see is not marked read", arguments: Hidden.allCases)
    func hiddenThreadIsNotRead(reason: Hidden) {
        var context = Self.visible
        reason.apply(to: &context)
        #expect(ThreadReadPolicy.target(context) == nil)
    }

    @Test("Reopening a thread needs a new bottom sample; late samples from the old pane are ignored")
    func viewportBelongsToItsPane() {
        let old = Self.identity
        let reopened = ThreadReadIdentity(
            accountID: old.accountID, sessionID: old.sessionID, roomID: old.roomID, timelineID: old.timelineID,
            rootID: old.rootID, threadSelectionID: old.threadSelectionID, presentationID: UUID())
        var viewport = ThreadReadViewport()
        viewport.record(true, from: old, current: old)
        #expect(viewport.isAtBottom(old))
        viewport.observe(reopened)
        #expect(!viewport.isAtBottom(reopened))
        viewport.record(true, from: old, current: reopened)
        #expect(!viewport.isAtBottom(reopened))
        viewport.record(true, from: reopened, current: reopened)
        viewport.record(false, from: old, current: reopened)
        #expect(viewport.isAtBottom(reopened))
    }
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

    @Test("Reading a thread sends one read receipt on the thread timeline and nothing else")
    func sendsThreadReceiptOnce() async throws {
        let f = fixture()
        let target = try target(f)
        try await f.service.markVisibleThreadRead(target, isVisible: { true })
        try await f.service.markVisibleThreadRead(target, isVisible: { true })
        #expect(f.thread.writes.all == ["read:$reply"])
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
        let blocking = Task { try await f.service.markVisibleRead(mainRead) }
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

    @Test("A thread receipt the SDK rejected is sent again on the next attempt")
    func failedReceiptIsRetried() async throws {
        let f = fixture()
        let target = try target(f)
        f.thread.failsWrites = true
        await #expect(throws: MatrixServiceError.self) {
            try await f.service.markVisibleThreadRead(target, isVisible: { true })
        }
        f.thread.failsWrites = false
        try await f.service.markVisibleThreadRead(target, isVisible: { true })
        #expect(f.thread.writes.all == ["read:$reply", "read:$reply"])
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
        #expect(f.thread.writes.all == ["read:$reply"])
    }
}
