import AppKit
import MatrixRustSDK
import OSLog

enum MatrixConnectionState: String, Equatable {
    case idle, connecting, running, offline, stopped, failed
}

struct MatrixConnectionFeedback: Equatable {
    let state: MatrixConnectionState
    let isRetrying: Bool
    let canRetry: Bool
    let errorMessage: String?
}

private final class ConnectionStateObserver: SyncServiceStateObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    let callback: @Sendable (SyncServiceState, Int) -> Void
    init(_ callback: @escaping @Sendable (SyncServiceState, Int) -> Void) { self.callback = callback }
    func onUpdate(state: SyncServiceState) {
        lock.lock()
        revision += 1
        let next = revision
        lock.unlock()
        callback(state, next)
    }
}

private final class RoomSyncStateObserver: RoomListServiceStateListener, @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    let callback: @Sendable (RoomListServiceState, Int) -> Void
    init(_ callback: @escaping @Sendable (RoomListServiceState, Int) -> Void) { self.callback = callback }
    func onUpdate(state: RoomListServiceState) {
        let next = lock.withLock {
            revision += 1
            return revision
        }
        callback(state, next)
    }
}

private final class SendQueueErrorObserver: SendQueueRoomErrorListener, @unchecked Sendable {
    let callback: @Sendable (String) -> Void
    init(_ callback: @escaping @Sendable (String) -> Void) { self.callback = callback }
    func onError(roomId: String, error: ClientError) { callback(roomId) }
}

@MainActor
final class ConnectionRecovery {
    private static let logger = Logger(subsystem: "ai.nuanu.slatrix", category: "connection")
    private let networkChanges: @Sendable () -> AsyncStream<NetworkRoute>
    private let wakeNotifications: NotificationCenter
    private let sendQueueResumeDelay: (Int) -> Duration
    init(
        networkChanges: @escaping @Sendable () -> AsyncStream<NetworkRoute> = { NetworkConnectivity.changes() },
        wakeNotifications: NotificationCenter? = nil,
        sendQueueResumeDelay: @escaping (Int) -> Duration = { .seconds(min(300, 5 << min($0, 6))) }
    ) {
        self.networkChanges = networkChanges
        self.wakeNotifications = wakeNotifications ?? NSWorkspace.shared.notificationCenter
        self.sendQueueResumeDelay = sendQueueResumeDelay
    }
    private struct Attempt {
        let id: UUID
        let task: Task<Void, Error>
    }
    private var generation = UUID()
    private var attachmentRequest = UUID()
    private var service: SyncService?
    private var client: Client?
    private var handle: TaskHandle?
    private var responseHandle: TaskHandle?
    private var responseObservation = UUID()
    private var attempt: Attempt?
    private var restartRequested = false
    private var revision = 0
    private var responseRevision = 0
    private var syncResponded = false
    private var hasConnected = false
    private var networkRoute: NetworkRoute?
    private var networkAvailable: Bool? { networkRoute.map { $0 != .offline } }
    private var networkTask: Task<Void, Never>?
    private var sdkState: SyncServiceState?
    private var onUpdate: ((MatrixConnectionFeedback) -> Void)?
    private var automaticRetry: Task<Void, Never>?
    private var failures = 0
    private var wakeObserver: NSObjectProtocol?
    private var sendQueueHandle: TaskHandle?
    private var sendQueueResumes: [String: Task<Void, Never>] = [:]
    private var sendQueueFailures: [String: Int] = [:]
    private(set) var feedback = MatrixConnectionFeedback(
        state: .idle, isRetrying: false, canRetry: false, errorMessage: nil)

    func attach(
        _ service: SyncService, client: Client? = nil, onUpdate: @escaping (MatrixConnectionFeedback) -> Void
    ) async throws {
        let request = UUID()
        attachmentRequest = request
        await stopCurrent()
        guard attachmentRequest == request else { throw CancellationError() }
        self.service = service
        self.client = client
        self.onUpdate = onUpdate
        let account = generation
        publish()
        handle = service.state(
            listener: ConnectionStateObserver { [weak self] state, revision in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == account, self.service != nil, revision > self.revision else {
                        return
                    }
                    self.revision = revision
                    if state != .running, state != .idle || self.sdkState != nil { self.syncResponded = false }
                    self.sdkState = state
                    self.publish()
                    self.scheduleAutomaticRetry()
                }
            })
        observeRoomSync(service, acceptSnapshot: true)
        sendQueueHandle = client?.subscribeToSendQueueStatus(
            listener: SendQueueErrorObserver { [weak self] roomID in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == account else { return }
                    self.resumeSending(roomID: roomID)
                }
            })
        wakeObserver = wakeNotifications.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == account else { return }
                self.failures = 0
                // From offline the SDK skips its server polling and syncs at once.
                try? await self.retry(restart: true)
            }
        }
        networkTask = Task { @MainActor [weak self, networkChanges] in
            for await route in networkChanges() {
                let available = route != .offline
                guard let self, !Task.isCancelled, self.generation == account else { return }
                // A live socket can still belong to the previous route after a handoff without an offline notice.
                let reconnect = available && self.networkRoute != nil && self.networkRoute != route
                self.networkRoute = route
                if !available || reconnect { self.stopObservingResponses() }
                self.publish()
                if reconnect {
                    self.failures = 0
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == account else { return }
                        try? await self.retry(restart: true)
                    }
                }
            }
        }
    }

    private func observeRoomSync(_ service: SyncService, acceptSnapshot: Bool) {
        let observation = UUID()
        responseObservation = observation
        // The first callback is a snapshot. After a restart, only a later response belongs to the new connection.
        responseRevision = acceptSnapshot ? 0 : 1
        responseHandle = service.roomListService().state(
            listener: RoomSyncStateObserver { [weak self] state, revision in
                Task { @MainActor [weak self] in
                    guard let self, self.responseHandle != nil, self.responseObservation == observation,
                        revision > self.responseRevision
                    else { return }
                    self.responseRevision = revision
                    self.syncResponded = state == .settingUp || state == .recovering || state == .running
                    self.publish()
                }
            })
    }

    private func stopObservingResponses() {
        responseHandle?.cancel()
        responseHandle = nil
        syncResponded = false
    }

    // A failed send stops its room's queue, and everything sent there after it waits. A reconnect resumes every room,
    // but a server error over a working connection brings none, so the room resumes on its own, a little later each
    // time, so a file the server keeps refusing isn't sent again and again.
    private func resumeSending(roomID: String) {
        guard feedback.state == .running, sendQueueResumes[roomID] == nil, let client else { return }
        let failures = sendQueueFailures[roomID, default: 0]
        sendQueueFailures[roomID] = failures + 1
        let account = generation
        let delay = sendQueueResumeDelay(failures)
        sendQueueResumes[roomID] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.generation == account else { return }
            self.sendQueueResumes[roomID] = nil
            guard let room = try? client.getRoom(roomId: roomID), !room.isSendQueueEnabled() else { return }
            room.enableSendQueue(enable: true)
        }
    }

    // Offline mode covers network loss; this restarts a sync that ended in an error or stopped on its own.
    private func scheduleAutomaticRetry() {
        guard networkAvailable != false else { return }
        guard sdkState == .error || sdkState == .terminated else {
            return
        }
        guard automaticRetry == nil else { return }
        let delay = failures == 0 ? 0 : min(30, 1 << min(failures - 1, 5))
        failures += 1
        let account = generation
        automaticRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.generation == account else { return }
            self.automaticRetry = nil
            try? await self.retry()
            // A failure seen while another start was in flight produced no new state to react to.
            if self.generation == account { self.scheduleAutomaticRetry() }
        }
    }

    func retry(restart: Bool = false) async throws {
        try Task.checkCancellation()
        guard let service else {
            throw MatrixServiceError.request("Still connecting. Try again in a moment.")
        }
        guard networkAvailable != false else { return }
        if restart { restartRequested = true }
        if let attempt {
            try await attempt.task.value
            try Task.checkCancellation()
            return
        }
        guard restartRequested || sdkState != .running else { return }
        let account = generation
        let id = UUID()
        // UniFFI start is not cancellable. Keep its actual await alive even if
        // a caller leaves; teardown must wait for it before stopping this SDK.
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            defer {
                // Clear ownership before waking callers, so a new restart cannot join an already finished attempt.
                if self.generation == account, self.attempt?.id == id {
                    self.attempt = nil
                    self.publish()
                }
            }
            repeat {
                guard self.generation == account else { throw CancellationError() }
                let shouldStop = self.restartRequested
                self.restartRequested = false
                if shouldStop {
                    self.stopObservingResponses()
                    self.publish()
                    await service.stop()
                }
                guard self.generation == account else { throw CancellationError() }
                guard self.networkAvailable != false else { return }
                if self.responseHandle == nil { self.observeRoomSync(service, acceptSnapshot: false) }
                await service.start()
                guard self.generation == account else { throw CancellationError() }
            } while self.restartRequested
        }
        attempt = Attempt(id: id, task: task)
        publish()
        let result = await task.result
        try Task.checkCancellation()
        try result.get()
        // Only a successful room sync reports Ready.
    }

    func stop() async {
        attachmentRequest = UUID()
        await stopCurrent()
    }

    private func stopCurrent() async {
        let previous = service
        let pending = attempt?.task
        generation = UUID()
        handle?.cancel()
        handle = nil
        stopObservingResponses()
        automaticRetry?.cancel()
        automaticRetry = nil
        sendQueueHandle?.cancel()
        sendQueueHandle = nil
        for resume in sendQueueResumes.values { resume.cancel() }
        sendQueueResumes = [:]
        sendQueueFailures = [:]
        networkTask?.cancel()
        networkTask = nil
        networkRoute = nil
        failures = 0
        if let wakeObserver { wakeNotifications.removeObserver(wakeObserver) }
        wakeObserver = nil
        service = nil
        client = nil
        attempt = nil
        restartRequested = false
        revision = 0
        hasConnected = false
        sdkState = nil
        feedback = MatrixConnectionFeedback(
            state: .idle, isRetrying: false, canRetry: false, errorMessage: nil)
        onUpdate = nil
        // Cancelling a Swift Task cannot stop its UniFFI future. Stopping only
        // after start returns prevents an old start from resurrecting sync.
        if let pending { _ = await pending.result }
        await previous?.stop()
    }

    private func publish() {
        var state: MatrixConnectionState =
            switch sdkState {
            case .running: syncResponded ? .running : .connecting
            case .offline: .offline
            case .terminated: .stopped
            case .error: .failed
            case .idle: .idle
            case nil: .connecting
            }
        let health = ConnectionHealth.resolve(
            network: networkAvailable, running: sdkState == .running,
            responded: syncResponded,
            interrupted: sdkState == .offline || sdkState == .error || sdkState == .terminated,
            previouslyConnected: hasConnected)
        if networkAvailable == false { state = .offline }
        let busy = attempt != nil
        if state == .running {
            hasConnected = true
            failures = 0
        }
        if state == .running, feedback.state != .running, let client {
            sendQueueFailures = [:]
            let account = generation
            Task { @MainActor [weak self] in
                guard self?.generation == account else { return }
                await client.enableAllSendQueues(enable: true)
            }
        }
        let next = MatrixConnectionFeedback(
            state: state, isRetrying: busy,
            canRetry: service != nil && networkAvailable != false && !busy && state != .running,
            errorMessage: health.notice)
        if feedback != next {
            Self.logger.log(
                "event=connection state=\(health.rawValue, privacy: .public) retrying=\(busy) responded=\(self.syncResponded)"
            )
        }
        feedback = next
        onUpdate?(feedback)
    }
}
