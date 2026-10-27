import Foundation
import MatrixRustSDK

/// A live timeline that, like the SDK, hands its cached items to a new listener as the first reset.
final class FakeLiveTimeline: Timeline, @unchecked Sendable {
    private let lock = NSLock()
    private let cached: [TimelineItem]
    private var listeners: [TimelineListener] = []
    private var handles: [FakeCancellableHandle] = []
    let pageGate = Gate()
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
        return false
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
    let membersGate = Gate()
    var memberList: [RoomMember] = []
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
        let timeline = FakeLiveTimeline(cached)
        timelines.append(timeline)
        return timeline
    }
    override func members() async throws -> RoomMembersIterator {
        await membersGate.wait()
        return FakeMembers(memberList)
    }
    override func subscribeToTypingNotifications(listener: TypingNotificationsListener) -> TaskHandle {
        FakeCancellableHandle(noHandle: .init())
    }
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
