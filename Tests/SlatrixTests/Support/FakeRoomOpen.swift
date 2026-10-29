import Foundation
import MatrixRustSDK

/// A live timeline that, like the SDK, hands its cached items to a new listener as the first reset.
final class FakeLiveTimeline: Timeline, @unchecked Sendable {
    private let lock = NSLock()
    private let cached: [TimelineItem]
    private var listeners: [TimelineListener] = []
    private var handles: [FakeCancellableHandle] = []
    let pageGate = Gate()
    /// Whether the next older page reaches the start of the room.
    var startReached: Bool {
        get { lock.withLock { reachedStart } }
        set { lock.withLock { reachedStart = newValue } }
    }
    private var reachedStart = false
    /// Read receipts sent through this timeline, as "read:" or "fully:" and the event.
    let receipts = Recorder<String>()
    var allListenersCancelled: Bool { lock.withLock { handles.allSatisfy(\.isCancelled) } }
    init(_ cached: [TimelineItem]) {
        self.cached = cached
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
    override func paginateBackwards(numEvents: UInt16) async throws -> Bool {
        await pageGate.wait()
        return startReached
    }
    /// Loaded around an older message, it already reaches the newest one.
    override func paginateForwards(numEvents: UInt16) async throws -> Bool { true }
    override func sendReadReceipt(receiptType: ReceiptType, eventId: String) async throws {
        receipts.append("\(receiptType == .read ? "read" : "fully"):\(eventId)")
    }
    /// Messages sent through this timeline into the room's send queue.
    let sent = Recorder<Void>()
    override func send(msg: RoomMessageEventContentWithoutRelation) async throws -> SendHandle {
        sent.append(())
        return SendHandle(noHandle: .init())
    }
    func emit(_ diff: [TimelineDiff]) {
        let callbacks = lock.withLock { listeners }
        for listener in callbacks { listener.onUpdate(diff: diff) }
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
    /// Holds a timeline opened at an older message, as the server's context request would.
    let eventGate = Gate()
    /// What a timeline opened at an older message loads; the cache when nil.
    var context: [TimelineItem]?
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
    override func membership() -> Membership { .joined }
    override func timelineWithConfiguration(configuration: TimelineConfiguration) async throws -> Timeline {
        focuses.append(configuration.focus)
        await buildGate.wait()
        if case .event = configuration.focus { await eventGate.wait() }
        var items = cached
        if case .event = configuration.focus, let context { items = context }
        let timeline = FakeLiveTimeline(items)
        timelines.append(timeline)
        return timeline
    }
    override func loadOrFetchEvent(eventId: String) async throws -> TimelineEvent {
        guard let root = threadRoots[eventId] else { throw URLError(.resourceUnavailable) }
        return FakeThreadReply(root: root)
    }
    override func members() async throws -> RoomMembersIterator {
        await membersGate.wait()
        return FakeMembers(memberList)
    }
    override func getPowerLevels() async throws -> RoomPowerLevels { FakePowerLevels(canNotifyRoom: canNotifyRoom) }
    override func subscribeToTypingNotifications(listener: TypingNotificationsListener) -> TaskHandle {
        FakeCancellableHandle(noHandle: .init())
    }
}

private final class FakeThreadReply: TimelineEvent, @unchecked Sendable {
    let root: String
    init(root: String) {
        self.root = root
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func threadRootEventId() -> String? { root }
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
    let subscriptions = Recorder<[String]>()
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func setRoomSubscriptions(roomIds: [String]) async throws { subscriptions.append(roomIds) }
}
