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

private final class SendQueueUpdateObserver: SendQueueRoomUpdateListener, @unchecked Sendable {
    let callback: @Sendable (String, RoomSendQueueUpdate) -> Void
    init(_ callback: @escaping @Sendable (String, RoomSendQueueUpdate) -> Void) { self.callback = callback }
    func onUpdate(roomId: String, update: RoomSendQueueUpdate) { callback(roomId, update) }
}

@MainActor
final class ConnectionRecovery {
    private static let logger = Logger(subsystem: "ai.nuanu.slatrix", category: "connection")
    private let networkChanges: @Sendable () -> AsyncStream<NetworkRoute>
    private let wakeNotifications: NotificationCenter
    private let waitToResumeSending: @MainActor (Int) async throws -> Void
    private let checkHealth: (@MainActor () async -> Bool)?
    private let healthCheckInterval: Duration
    init(
        networkChanges: @escaping @Sendable () -> AsyncStream<NetworkRoute> = { NetworkConnectivity.changes() },
        wakeNotifications: NotificationCenter? = nil,
        waitToResumeSending: @escaping @MainActor (Int) async throws -> Void = { failures in
            try await Task.sleep(for: .seconds(min(300, 5 << min(failures, 6))))
        },
        checkHealth: (@MainActor () async -> Bool)? = nil,
        healthCheckInterval: Duration = .seconds(15)
    ) {
        self.networkChanges = networkChanges
        self.wakeNotifications = wakeNotifications ?? NSWorkspace.shared.notificationCenter
        self.waitToResumeSending = waitToResumeSending
        self.checkHealth = checkHealth
        self.healthCheckInterval = healthCheckInterval
    }
    private struct Attempt {
        let id: UUID
        let task: Task<Void, Error>
    }
    private var generation = UUID()
    private var attachmentRequest = UUID()
    private var service: SyncService?
    private var client: Client?
    private var homeserverURL: String?
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
    private var onSendingResumed: (() -> Void)?
    private var onSendQueueUpdate: ((String, RoomSendQueueUpdate) -> Void)?
    private var automaticRetry: Task<Void, Never>?
    private var failures = 0
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var sleeping = false
    private var sleepStopTask: (id: UUID, task: Task<Void, Never>)?
    private var sendQueueHandle: TaskHandle?
    private var sendQueueResumes: [String: Task<Void, Never>] = [:]
    private var sendQueueFailures: [String: Int] = [:]
    private var healthCheckTask: Task<Void, Never>?
    private var lastHealthCheck: ContinuousClock.Instant?
    var isAttached: Bool { service != nil }
    private(set) var feedback = MatrixConnectionFeedback(
        state: .idle, isRetrying: false, canRetry: false, errorMessage: nil)

    func attach(
        _ service: SyncService, client: Client? = nil, homeserverURL: String? = nil,
        onSendingResumed: @escaping () -> Void = {},
        onSendQueueUpdate: @escaping (String, RoomSendQueueUpdate) -> Void = { _, _ in },
        onUpdate: @escaping (MatrixConnectionFeedback) -> Void
    ) async throws {
        let request = UUID()
        attachmentRequest = request
        await stopCurrent()
        guard attachmentRequest == request else { throw CancellationError() }
        self.service = service
        self.client = client
        self.homeserverURL = homeserverURL
        self.onUpdate = onUpdate
        self.onSendingResumed = onSendingResumed
        self.onSendQueueUpdate = onSendQueueUpdate
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
                    if state == .running, !self.sleeping, self.networkAvailable != false,
                        self.responseHandle == nil, self.attempt == nil, let activeService = self.service
                    {
                        self.observeRoomSync(activeService, acceptSnapshot: true)
                    }
                    self.publish()
                    self.scheduleAutomaticRetry()
                }
            })
        observeRoomSync(service, acceptSnapshot: true)
        if let client {
            let queueHandle = try await client.subscribeToSendQueueUpdates(
                listener: SendQueueUpdateObserver { [weak self] roomID, update in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == account else { return }
                        self.handleSendQueueUpdate(roomID: roomID, update: update, account: account)
                    }
                })
            guard attachmentRequest == request, self.generation == account else {
                queueHandle.cancel()
                throw CancellationError()
            }
            sendQueueHandle = queueHandle
        }
        sleepObserver = wakeNotifications.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == account else { return }
                self.pauseForSleep(account: account)
            }
        }
        wakeObserver = wakeNotifications.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == account else { return }
                self.sleeping = false
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
                if reconnect && !self.sleeping { self.restartRequested = true }
                self.publish()
                if reconnect && !self.sleeping {
                    self.failures = 0
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == account, !self.sleeping else { return }
                        try? await self.retry(restart: true)
                    }
                }
            }
        }
    }

    private func pauseForSleep(account: UUID) {
        guard !sleeping, let activeService = service else { return }
        sleeping = true
        automaticRetry?.cancel()
        automaticRetry = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil
        for resume in sendQueueResumes.values { resume.cancel() }
        sendQueueResumes = [:]
        stopObservingResponses()
        publish()
        let pendingAttempt = attempt?.task
        let previousSleepStop = sleepStopTask?.task
        let stopID = UUID()
        sleepStopTask = (
            stopID,
            Task { @MainActor [weak self] in
                defer { if let self, self.sleepStopTask?.id == stopID { self.sleepStopTask = nil } }
                await previousSleepStop?.value
                if let pendingAttempt { _ = await pendingAttempt.result }
                guard let self, self.generation == account, self.sleeping else { return }
                await activeService.stop()
            }
        )
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

    private func handleSendQueueUpdate(roomID: String, update: RoomSendQueueUpdate, account: UUID) {
        onSendQueueUpdate?(roomID, update)
        switch update {
        case .sendError(_, _, let isRecoverable):
            if isRecoverable {
                resumeSending(roomID: roomID)
                checkHealthAfterSendFailure(account: account)
            } else {
                sendQueueResumes.removeValue(forKey: roomID)?.cancel()
            }
        case .sentEvent:
            cancelRoomResume(roomID: roomID)
        case .cancelledLocalEvent:
            cancelRoomResume(roomID: roomID)
            if feedback.state == .running, let room = try? client?.getRoom(roomId: roomID),
                !room.isSendQueueEnabled()
            {
                room.enableSendQueue(enable: true)
            }
        default:
            break
        }
    }

    func cancelRoomResume(roomID: String) {
        sendQueueResumes.removeValue(forKey: roomID)?.cancel()
        sendQueueFailures.removeValue(forKey: roomID)
    }

    // A recoverable send error while sync still claims running can mean a blackholed socket. Probe quickly rather
    // than waiting minutes for SlidingSync's TCP timeout.
    private func checkHealthAfterSendFailure(account: UUID) {
        guard feedback.state == .running, !sleeping, healthCheckTask == nil else { return }
        let now = ContinuousClock.now
        if let lastHealthCheck, now - lastHealthCheck < healthCheckInterval { return }
        lastHealthCheck = now
        let probe = checkHealth
        let serverURL = homeserverURL
        healthCheckTask = Task { @MainActor [weak self] in
            defer { if let self, self.generation == account { self.healthCheckTask = nil } }
            let healthy: Bool
            if let probe {
                healthy = await probe()
            } else {
                healthy = await Self.probeServerHealth(homeserverURL: serverURL)
            }
            guard let self, !Task.isCancelled, self.generation == account, !self.sleeping,
                self.feedback.state == .running, !healthy
            else { return }
            self.failures = 0
            try? await self.retry(restart: true)
        }
    }

    private nonisolated static func probeServerHealth(homeserverURL: String?) async -> Bool {
        guard let homeserverURL, var url = URL(string: homeserverURL) else { return true }
        url.append(path: "_matrix/client/versions")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    // A failed send stops its room's queue, and everything sent there after it waits. A reconnect resumes every room,
    // but a server error over a working connection brings none, so the room resumes on its own, a little later each
    // time, so a file the server keeps refusing isn't sent again and again.
    private func resumeSending(roomID: String) {
        guard feedback.state == .running, sendQueueResumes[roomID] == nil, let client else { return }
        let failures = sendQueueFailures[roomID, default: 0]
        sendQueueFailures[roomID] = failures + 1
        let account = generation
        sendQueueResumes[roomID] = Task { [weak self, waitToResumeSending] in
            try? await waitToResumeSending(failures)
            guard let self, !Task.isCancelled, self.generation == account else { return }
            self.sendQueueResumes[roomID] = nil
            guard self.feedback.state == .running, let room = try? client.getRoom(roomId: roomID),
                !room.isSendQueueEnabled()
            else { return }
            room.enableSendQueue(enable: true)
        }
    }

    // Offline mode covers network loss; this restarts a sync that ended in an error or stopped on its own.
    private func scheduleAutomaticRetry() {
        guard !sleeping, networkAvailable != false else { return }
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
        guard !sleeping, networkAvailable != false else { return }
        if restart { restartRequested = true }
        if let attempt {
            try await attempt.task.value
            try Task.checkCancellation()
            return
        }
        guard restartRequested || sdkState != .running || responseHandle == nil else { return }
        let account = generation
        let id = UUID()
        // Capture any in-flight sleep stop before publishing `attempt`, so a sleep arriving before this task starts
        // waits on `attempt` while this task does not wait back on the newer sleep stop (no circular await).
        let pendingSleepStop = sleepStopTask?.task
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
            await pendingSleepStop?.value
            repeat {
                guard self.generation == account, !self.sleeping else { throw CancellationError() }
                let shouldStop = self.restartRequested
                self.restartRequested = false
                if shouldStop {
                    self.stopObservingResponses()
                    self.publish()
                    await service.stop()
                }
                guard self.generation == account, !self.sleeping else { return }
                guard self.networkAvailable != false else { return }
                if self.responseHandle == nil { self.observeRoomSync(service, acceptSnapshot: false) }
                await service.start()
                guard self.generation == account else { throw CancellationError() }
                if !self.sleeping, self.networkAvailable != false, self.responseHandle == nil {
                    self.restartRequested = true
                }
            } while self.restartRequested && !self.sleeping
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
        let pendingSleepStop = sleepStopTask?.task
        generation = UUID()
        handle?.cancel()
        handle = nil
        stopObservingResponses()
        automaticRetry?.cancel()
        automaticRetry = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil
        lastHealthCheck = nil
        sendQueueHandle?.cancel()
        sendQueueHandle = nil
        for resume in sendQueueResumes.values { resume.cancel() }
        sendQueueResumes = [:]
        sendQueueFailures = [:]
        networkTask?.cancel()
        networkTask = nil
        networkRoute = nil
        failures = 0
        sleeping = false
        sleepStopTask = nil
        if let sleepObserver { wakeNotifications.removeObserver(sleepObserver) }
        sleepObserver = nil
        if let wakeObserver { wakeNotifications.removeObserver(wakeObserver) }
        wakeObserver = nil
        service = nil
        client = nil
        homeserverURL = nil
        attempt = nil
        restartRequested = false
        revision = 0
        hasConnected = false
        sdkState = nil
        feedback = MatrixConnectionFeedback(
            state: .idle, isRetrying: false, canRetry: false, errorMessage: nil)
        onUpdate = nil
        onSendingResumed = nil
        onSendQueueUpdate = nil
        // Cancelling a Swift Task cannot stop its UniFFI future. Stopping only
        // after start returns prevents an old start from resurrecting sync.
        if let pending { _ = await pending.result }
        await pendingSleepStop?.value
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
            network: networkAvailable, foreground: !sleeping, running: sdkState == .running,
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
                guard let self, self.generation == account, self.feedback.state == .running else { return }
                await client.enableAllSendQueues(enable: true)
                self.onSendingResumed?()
            }
        }
        let next = MatrixConnectionFeedback(
            state: state, isRetrying: busy,
            canRetry: service != nil && !sleeping && networkAvailable != false && !busy && state != .running,
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
