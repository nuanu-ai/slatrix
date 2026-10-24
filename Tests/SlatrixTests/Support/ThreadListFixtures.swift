import Foundation
import MatrixRustSDK

/// A room's thread list: one page of thread summaries that the test can replay.
final class FakeThreadList: ThreadListService, @unchecked Sendable {
    let values: [ThreadListItem]
    let pages = Recorder<Void>()
    private let lock = NSLock()
    private var listeners: [ThreadListEntriesListener] = []
    init(_ values: [ThreadListItem] = []) {
        self.values = values
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func paginate() async throws { pages.append(()) }
    override func items() -> [ThreadListItem] { values }
    override func paginationState() -> ThreadListPaginationState { .idle(endReached: true) }
    override func subscribeToItemsUpdates(listener: ThreadListEntriesListener) -> TaskHandle {
        lock.withLock { listeners.append(listener) }
        listener.onUpdate(diff: [.reset(values: values)])
        return FakeCancellableHandle(noHandle: .init())
    }
    override func subscribeToPaginationStateUpdates(listener: ThreadListPaginationStateListener) -> TaskHandle {
        listener.onUpdate(state: .idle(endReached: true))
        return FakeCancellableHandle(noHandle: .init())
    }
    func replaySnapshot() {
        for listener in lock.withLock({ listeners }) { listener.onUpdate(diff: [.reset(values: values)]) }
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
    var fail = false
    init(threads: FakeThreadList = FakeThreadList(), timelines: [String: FakeEventTimeline] = [:]) {
        self.threads = threads
        self.timelines = timelines
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func membership() -> Membership { .joined }
    override func threadListService() -> ThreadListService { threads }
    override func timelineWithConfiguration(configuration: TimelineConfiguration) async throws -> Timeline {
        configurations.append(configuration)
        guard !fail, case .event(let eventID, _, _) = configuration.focus, let timeline = timelines[eventID] else {
            throw ClientError.Generic(msg: "preview unavailable", details: nil)
        }
        return timeline
    }
}

/// Answers every room lookup with the same room.
final class FakeThreadClient: Client, @unchecked Sendable {
    let room: FakeThreadRoom
    init(_ room: FakeThreadRoom) {
        self.room = room
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func getRoom(roomId: String) throws -> Room? { room }
}

func threadEvent(_ id: String, timestamp: UInt64 = 1_000, content: TimelineItemContent? = nil) -> ThreadListItemEvent {
    ThreadListItemEvent(
        eventId: id, timestamp: timestamp, sender: "@alice:example.org", senderProfile: .unavailable, isOwn: false,
        content: content ?? textEvent(id, body: "Original snapshot").content)
}
