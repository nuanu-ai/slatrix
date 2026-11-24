import Foundation
import MatrixRustSDK

/// A room's thread list: one page of thread summaries that the test can replay.
final class FakeThreadList: ThreadListService, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [ThreadListItem]
    let pages = Recorder<Void>()
    private var listeners: [ThreadListEntriesListener] = []
    init(_ values: [ThreadListItem] = []) {
        self.storedValues = values
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    var values: [ThreadListItem] {
        get { lock.withLock { storedValues } }
        set { lock.withLock { storedValues = newValue } }
    }
    override func paginate() async throws { pages.append(()) }
    override func items() -> [ThreadListItem] { values }
    override func paginationState() -> ThreadListPaginationState { .idle(endReached: true) }
    override func subscribeToItemsUpdates(listener: ThreadListEntriesListener) -> TaskHandle {
        let current = lock.withLock {
            listeners.append(listener)
            return storedValues
        }
        listener.onUpdate(diff: [.reset(values: current)])
        return FakeCancellableHandle(noHandle: .init())
    }
    override func subscribeToPaginationStateUpdates(listener: ThreadListPaginationStateListener) -> TaskHandle {
        listener.onUpdate(state: .idle(endReached: true))
        return FakeCancellableHandle(noHandle: .init())
    }
    func replaySnapshot() {
        let (callbacks, current) = lock.withLock { (listeners, storedValues) }
        for listener in callbacks { listener.onUpdate(diff: [.reset(values: current)]) }
    }
    func emit(_ next: [ThreadListItem]) {
        let callbacks = lock.withLock {
            storedValues = next
            return listeners
        }
        for listener in callbacks { listener.onUpdate(diff: [.reset(values: next)]) }
    }
}

/// An event-focused timeline holding one event; `emit` replaces it and notifies listeners.
final class FakeEventTimeline: Timeline, @unchecked Sendable {
    private let lock = NSLock()
    private var value: EventTimelineItem
    private var listeners: [TimelineListener] = []
    private var handles: [FakeCancellableHandle] = []
    let sideEffects = Recorder<String>()
    var allListenersCancelled: Bool { lock.withLock { handles.allSatisfy(\.isCancelled) } }
    init(_ value: EventTimelineItem) {
        self.value = value
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func addListener(listener: TimelineListener) async -> TaskHandle {
        let handle = FakeCancellableHandle(noHandle: .init())
        lock.withLock {
            listeners.append(listener)
            handles.append(handle)
        }
        listener.onUpdate(diff: [])
        return handle
    }
    override func getEventTimelineItemByEventId(eventId: String) async throws -> EventTimelineItem {
        lock.withLock { value }
    }
    override func markAsRead(receiptType: ReceiptType) async throws { sideEffects.append("read") }
    override func paginateBackwards(numEvents: UInt16) async throws -> Bool {
        sideEffects.append("paginate")
        return true
    }
    func emit(_ value: EventTimelineItem) {
        let callbacks = lock.withLock {
            self.value = value
            return listeners
        }
        for callback in callbacks { callback.onUpdate(diff: []) }
    }
}

/// A joined room with a thread list and event-focused timelines keyed by event ID.
final class FakeThreadRoom: Room, @unchecked Sendable {
    let threads: FakeThreadList
    let timelines: [String: FakeEventTimeline]
    let configurations = Recorder<TimelineConfiguration>()
    let receiptGate = Gate()
    private let lock = NSLock()
    private var storedReceipts: [ReceiptThread: UserReceipt]
    private var storedPrivateReceipts: [ReceiptThread: UserReceipt]
    var fail = false
    init(
        threads: FakeThreadList = FakeThreadList(), timelines: [String: FakeEventTimeline] = [:],
        receipts: [ReceiptThread: UserReceipt] = [:], privateReceipts: [ReceiptThread: UserReceipt] = [:]
    ) {
        self.threads = threads
        self.timelines = timelines
        self.storedReceipts = receipts
        self.storedPrivateReceipts = privateReceipts
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    var receipts: [ReceiptThread: UserReceipt] {
        get { lock.withLock { storedReceipts } }
        set { lock.withLock { storedReceipts = newValue } }
    }
    var privateReceipts: [ReceiptThread: UserReceipt] {
        get { lock.withLock { storedPrivateReceipts } }
        set { lock.withLock { storedPrivateReceipts = newValue } }
    }
    override func membership() -> Membership { .joined }
    override func threadListService() -> ThreadListService { threads }
    override func loadUserReceipt(receiptType: ReceiptType, thread: ReceiptThread, userId: String) async throws
        -> UserReceipt?
    {
        await receiptGate.wait()
        switch receiptType {
        case .read: return lock.withLock { storedReceipts[thread] }
        case .readPrivate: return lock.withLock { storedPrivateReceipts[thread] }
        case .fullyRead: return nil
        }
    }
    override func timelineWithConfiguration(configuration: TimelineConfiguration) async throws -> Timeline {
        configurations.append(configuration)
        guard !fail, case .event(let eventID, _, _) = configuration.focus, let timeline = timelines[eventID] else {
            throw ClientError.Generic(msg: "preview unavailable", details: nil)
        }
        return timeline
    }
}

/// Answers a room lookup with that room in `rooms`, or else with `room`.
final class FakeThreadClient: Client, @unchecked Sendable {
    let room: FakeThreadRoom
    let rooms: [String: FakeThreadRoom]
    init(_ room: FakeThreadRoom, rooms: [String: FakeThreadRoom] = [:]) {
        self.room = room
        self.rooms = rooms
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func getRoom(roomId: String) throws -> Room? { rooms[roomId] ?? room }
}

func threadEvent(
    _ id: String, timestamp: UInt64 = 1_000, sender: String = "@alice:example.org", isOwn: Bool = false,
    content: TimelineItemContent? = nil
) -> ThreadListItemEvent {
    ThreadListItemEvent(
        eventId: id, timestamp: timestamp, sender: sender, senderProfile: .unavailable, isOwn: isOwn,
        content: content ?? textEvent(id, body: "Original snapshot").content)
}
