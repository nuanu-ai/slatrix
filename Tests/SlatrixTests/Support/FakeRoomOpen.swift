import Foundation
import MatrixRustSDK

@testable import Slatrix

/// A live timeline that, like the SDK, hands its cached items to a new listener as the first reset.
final class FakeLiveTimeline: Timeline, @unchecked Sendable {
    private let lock = NSLock()
    private let cached: [TimelineItem]
    private var listeners: [TimelineListener] = []
    private var handles: [FakeCancellableHandle] = []
    let pageGate: Gate
    let forwardGate: Gate
    /// Whether the next older page reaches the start of the room.
    var startReached: Bool {
        get { lock.withLock { reachedStart } }
        set { lock.withLock { reachedStart = newValue } }
    }
    private var reachedStart = false
    /// What the next older pages answer, in order, before `startReached` does.
    var pageAnswers: [Bool] {
        get { lock.withLock { answers } }
        set { lock.withLock { answers = newValue } }
    }
    private var answers: [Bool] = []
    /// What the next older pages add before what the timeline holds, in order.
    var olderPages: [[TimelineItem]] {
        get { lock.withLock { pages } }
        set { lock.withLock { pages = newValue } }
    }
    private var pages: [[TimelineItem]] = []
    /// Why the next older page fails, as a lost connection would make it; it fails once.
    var pageFailure: Error? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    private var failure: Error?
    /// Read receipts sent through this timeline, as "read:" or "fully:" and the event.
    let receipts = Recorder<String>()
    /// False until a listener is added: a timeline still being set up is not closed.
    var allListenersCancelled: Bool { lock.withLock { !handles.isEmpty && handles.allSatisfy(\.isCancelled) } }
    init(_ cached: [TimelineItem], pageGate: Gate = Gate(), forwardGate: Gate = Gate()) {
        self.cached = cached
        self.pageGate = pageGate
        self.forwardGate = forwardGate
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func addListener(listener: TimelineListener) async -> TaskHandle {
        let handle = FakeCancellableHandle(noHandle: .init())
        lock.withLock {
            listeners.append(listener)
            handles.append(handle)
        }
        listener.onUpdate(diff: [.reset(values: cached)])
        return handle
    }
    private var paging = false
    /// One older page at a time: asking for another while one is on its way fails, as a busy paginator would.
    override func paginateBackwards(numEvents: UInt16) async throws -> Bool {
        try lock.withLock {
            if paging { throw URLError(.cancelled) }
            paging = true
        }
        defer { lock.withLock { paging = false } }
        await pageGate.wait()
        if let failure = lock.withLock({ () -> Error? in
            defer { self.failure = nil }
            return self.failure
        }) {
            throw failure
        }
        if let page = lock.withLock({ pages.isEmpty ? nil : pages.removeFirst() }) {
            emit(page.reversed().map { .pushFront(value: $0) })
        }
        return lock.withLock { answers.isEmpty ? reachedStart : answers.removeFirst() }
    }
    /// Loaded around an older message, it already reaches the newest one.
    override func paginateForwards(numEvents: UInt16) async throws -> Bool {
        await forwardGate.wait()
        return true
    }
    override func sendReadReceipt(receiptType: ReceiptType, eventId: String) async throws {
        receipts.append("\(receiptType == .read ? "read" : "fully"):\(eventId)")
    }
    /// As the SDK does, on the newest event this timeline was given.
    override func markAsRead(receiptType: ReceiptType) async throws {
        let latest = lock.withLock { newest }
        try await sendReadReceipt(receiptType: receiptType, eventId: latest ?? "")
    }
    private lazy var newest: String? = cached.compactMap(Self.eventID).last
    private static func eventID(_ item: TimelineItem) -> String? { item.asEvent().map(eventID) }
    private static func eventID(_ event: EventTimelineItem) -> String {
        MatrixMapping.identifier(event.eventOrTransactionId)
    }
    /// Messages sent through this timeline into the room's send queue.
    let sent = Recorder<Void>()
    /// Holds a send before the queue takes it.
    let sendGate = Gate()
    /// Each send's transaction is "txn-" and how many this timeline has sent.
    override func send(msg: RoomMessageEventContentWithoutRelation) async throws -> SendHandle {
        await sendGate.wait()
        sent.append(())
        return FakeSendHandle("txn-\(sent.all.count)")
    }
    func emit(_ diff: [TimelineDiff]) {
        let added = diff.flatMap { change -> [TimelineItem] in
            switch change {
            case .pushBack(let value): [value]
            case .append(let values), .reset(let values): values
            default: []
            }
        }
        let callbacks = lock.withLock {
            if let last = added.compactMap(Self.eventID).last { newest = last }
            for change in diff {
                switch change {
                case .append(let values): items += values
                case .clear: items = []
                case .pushFront(let value): items.insert(value, at: 0)
                case .pushBack(let value): items.append(value)
                case .popFront: items.removeFirst()
                case .popBack: items.removeLast()
                case .insert(let index, let value): items.insert(value, at: Int(index))
                case .set(let index, let value): items[Int(index)] = value
                case .remove(let index): items.remove(at: Int(index))
                case .truncate(let length): items.removeSubrange(Int(length)...)
                case .reset(let values): items = values
                }
            }
            return listeners
        }
        for listener in callbacks { listener.onUpdate(diff: diff) }
    }
    /// What this timeline holds, as its listeners last heard it; like the SDK, it acts only on those events.
    private lazy var items = cached
    /// Reactions toggled through this timeline, as the key and the event.
    let reactions = Recorder<String>()
    override func toggleReaction(itemId: EventOrTransactionId, key: String) async throws -> Bool {
        let id = MatrixMapping.identifier(itemId)
        try hold(id)
        reactions.append("\(key) \(id)")
        return true
    }
    /// Why the next details fetch fails, as a lost connection would make it.
    var detailsFailure: Error?
    override func fetchDetailsForEvent(eventId: String) async throws {
        try hold(eventId)
        if let detailsFailure { throw detailsFailure }
    }
    override func getEventTimelineItemByEventId(eventId: String) async throws -> EventTimelineItem {
        try hold(eventId)
    }
    @discardableResult private func hold(_ id: String) throws -> EventTimelineItem {
        let event = lock.withLock { items.lazy.compactMap { $0.asEvent() }.first { Self.eventID($0) == id } }
        guard let event else { throw URLError(.resourceUnavailable) }
        return event
    }
}

/// A joined room whose event cache holds `cached`. Each timeline it builds is recorded; members wait on a gate.
final class FakeOpenRoom: Room, @unchecked Sendable {
    private let identifier: String
    private let cached: [TimelineItem]
    let timelines = Recorder<FakeLiveTimeline>()
    let focuses = Recorder<TimelineFocus>()
    /// Holds reading the event cache, as a slow disk would.
    let buildGate = Gate()
    /// Holds reading an older page in every timeline the room builds.
    let pageGate = Gate()
    /// Holds reading a newer page in every timeline the room builds.
    let forwardGate = Gate()
    /// Holds a timeline opened at an older message, as the server's context request would.
    let eventGate = Gate()
    /// What a timeline opened at an older message loads; the cache when nil.
    var focusedItems: [TimelineItem]?
    /// Why a timeline opened at an older message fails to load, as a lost connection would make it.
    var focusedError: Error?
    /// Why building any timeline fails; when `buildFailuresRemaining` is set, only that many attempts fail.
    var buildError: Error?
    var buildFailuresRemaining: Int?
    private let buildLock = NSLock()
    /// What a thread's timeline loads; the cache when nil.
    var threadItems: [TimelineItem]?
    /// The older pages of a thread's replies, newest page first.
    var threadPages: [[TimelineItem]] = []
    /// Whether the thread's first older page reaches its start.
    var threadStartReached = false
    /// Thread replies the room can load, by event ID, with their thread's root.
    var threadRoots: [String: String] = [:]
    let membersGate = Gate()
    var memberList: [RoomMember] = []
    /// Whether your power level lets you notify the whole room.
    var canNotifyRoom = false
    init(_ id: String, cached: [TimelineItem]) {
        identifier = id
        self.cached = cached
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func id() -> String { identifier }
    /// Joined unless the test invites you.
    var joined = true
    override func membership() -> Membership { joined ? .joined : .invited }
    override func timelineWithConfiguration(configuration: TimelineConfiguration) async throws -> Timeline {
        focuses.append(configuration.focus)
        await buildGate.wait()
        let nextBuildError: Error? = buildLock.withLock {
            guard let buildError else { return nil }
            if let remaining = buildFailuresRemaining {
                guard remaining > 0 else { return nil }
                buildFailuresRemaining = remaining - 1
            }
            return buildError
        }
        if let nextBuildError { throw nextBuildError }
        if case .event = configuration.focus {
            await eventGate.wait()
            if let focusedError { throw focusedError }
        }
        var items = cached
        if case .event = configuration.focus, let focusedItems { items = focusedItems }
        if case .thread = configuration.focus, let threadItems { items = threadItems }
        let timeline = FakeLiveTimeline(items, pageGate: pageGate, forwardGate: forwardGate)
        if case .thread = configuration.focus {
            timeline.olderPages = threadPages
            timeline.startReached = threadStartReached
        }
        timelines.append(timeline)
        return timeline
    }
    /// The events looked up one by one.
    let lookups = Recorder<String>()
    override func loadOrFetchEvent(eventId: String) async throws -> TimelineEvent {
        lookups.append(eventId)
        guard let root = threadRoots[eventId] else { throw URLError(.resourceUnavailable) }
        return FakeThreadReply(root: root)
    }
    private let queueLock = NSLock()
    private var queueListeners: [(listener: SendQueueListener, handle: FakeCancellableHandle)] = []
    override func subscribeToSendQueueUpdates(listener: SendQueueListener) async throws -> TaskHandle {
        let handle = FakeCancellableHandle(noHandle: .init())
        queueLock.withLock { queueListeners.append((listener, handle)) }
        return handle
    }
    /// Tells whoever follows the room's send queue about `update`.
    func queue(_ update: RoomSendQueueUpdate) {
        for (listener, _) in queueLock.withLock({ queueListeners }) { listener.onUpdate(update: update) }
    }
    /// Whether everyone who followed the room's send queue has let go of it.
    var queueReleased: Bool { queueLock.withLock { queueListeners.allSatisfy(\.handle.isCancelled) } }
    /// Events sent straight to the room, past its send queue, as their type and JSON content.
    let raw = Recorder<(type: String, content: String)>()
    override func sendRaw(eventType: String, content: String) async throws -> String {
        raw.append((eventType, content))
        return "$raw"
    }
    override func members() async throws -> RoomMembersIterator {
        await membersGate.wait()
        return FakeMembers(memberList)
    }
    override func getPowerLevels() async throws -> RoomPowerLevels { FakePowerLevels(canNotifyRoom: canNotifyRoom) }
    override func subscribeToTypingNotifications(listener: TypingNotificationsListener) -> TaskHandle {
        FakeCancellableHandle(noHandle: .init())
    }
    override func typingNotice(isTyping: Bool) async throws {}
}

private final class FakeThreadReply: TimelineEvent, @unchecked Sendable {
    let root: String
    init(root: String) {
        self.root = root
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func threadRootEventId() -> String? { root }
    // Asked whether it was deleted.
    override func content() throws -> TimelineEventContent {
        .messageLike(
            content: .roomMessage(
                messageType: .text(content: TextMessageContent(body: "Reply", formatted: nil)), inReplyToEventId: nil))
    }
}

private final class FakePowerLevels: RoomPowerLevels, @unchecked Sendable {
    let canNotifyRoom: Bool
    init(canNotifyRoom: Bool) {
        self.canNotifyRoom = canNotifyRoom
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func canOwnUserTriggerRoomNotification() -> Bool { canNotifyRoom }
}

final class FakeMembers: RoomMembersIterator, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [RoomMember]
    init(_ members: [RoomMember]) {
        remaining = members
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func nextChunk(chunkSize: UInt32) -> [RoomMember]? {
        lock.withLock {
            defer { remaining = [] }
            return remaining.isEmpty ? nil : remaining
        }
    }
}

/// Records each set of rooms the app asks sync to keep subscribed.
final class FakeRoomListService: RoomListService, @unchecked Sendable {
    private let lock = NSLock()
    let subscriptions = Recorder<[String]>()
    private var failNext = false
    var failsSubscriptions: Bool {
        get { lock.withLock { failNext } }
        set { lock.withLock { failNext = newValue } }
    }
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func setRoomSubscriptions(roomIds: [String]) async throws {
        subscriptions.append(roomIds)
        if failsSubscriptions { throw URLError(.notConnectedToInternet) }
    }
}

/// A send's handle, carrying its transaction.
final class FakeSendHandle: SendHandle, @unchecked Sendable {
    private let transaction: String
    init(_ transaction: String) {
        self.transaction = transaction
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func transactionId() -> String { transaction }
}
