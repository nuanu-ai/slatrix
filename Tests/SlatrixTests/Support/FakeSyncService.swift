import Foundation
import MatrixRustSDK

/// A sync service whose state the test drives; `start()` emits `stateOnStart`.
final class FakeSyncService: SyncService, @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [SyncServiceStateObserver] = []
    private var current: SyncServiceState
    private var starts = 0
    private var stops = 0
    var stateOnStart: SyncServiceState? = .running
    var confirmsSync = true
    let roomSync: FakeConnectionRoomList
    let startGate = Gate()
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    init(state: SyncServiceState = .idle) {
        current = state
        roomSync = FakeConnectionRoomList(state: state == .running ? .running : .initial)
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }

    override func roomListService() -> RoomListService { roomSync }

    override func state(listener: SyncServiceStateObserver) -> TaskHandle {
        let initial = lock.withLock {
            observers.append(listener)
            return current
        }
        listener.onUpdate(state: initial)
        return FakeCancellableHandle(noHandle: .init())
    }
    override func start() async {
        lock.withLock { starts += 1 }
        await startGate.wait()
        if let stateOnStart { emit(stateOnStart) }
    }
    override func stop() async {
        lock.withLock { stops += 1 }
        emit(.idle)
    }
    func emit(_ state: SyncServiceState) {
        let callbacks = lock.withLock {
            current = state
            return observers
        }
        for item in callbacks { item.onUpdate(state: state) }
        if confirmsSync {
            if state == .running { roomSync.emit(.running) }
            if state == .offline || state == .error { roomSync.emit(.error) }
        }
    }
}

final class FakeConnectionRoomList: RoomListService, @unchecked Sendable {
    private let lock = NSLock()
    private var current: RoomListServiceState
    private var observers: [RoomListServiceStateListener] = []
    init(state: RoomListServiceState) {
        current = state
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func state(listener: RoomListServiceStateListener) -> TaskHandle {
        let initial = lock.withLock {
            observers.append(listener)
            return current
        }
        listener.onUpdate(state: initial)
        return FakeCancellableHandle(noHandle: .init())
    }
    func emit(_ state: RoomListServiceState) {
        let callbacks = lock.withLock {
            current = state
            return observers
        }
        for observer in callbacks { observer.onUpdate(state: state) }
    }
}
