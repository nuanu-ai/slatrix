import AppKit
import MatrixRustSDK

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

@MainActor
final class ConnectionRecovery {
    private struct Attempt {
        let id: UUID
        let task: Task<Void, Error>
    }
    private var generation = UUID()
    private var attachmentRequest = UUID()
    private var service: SyncService?
    private var client: Client?
    private var handle: TaskHandle?
    private var attempt: Attempt?
    private var revision = 0
    private var sdkState: SyncServiceState?
    private var onUpdate: ((MatrixConnectionFeedback) -> Void)?
    private var automaticRetry: Task<Void, Never>?
    private var failures = 0
    private var wakeObserver: NSObjectProtocol?
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
                    // A network error pauses a room's send queue; what waited there goes out once sync is back.
                    if state == .running, self.sdkState != .running, let client = self.client {
                        Task { await client.enableAllSendQueues(enable: true) }
                    }
                    self.sdkState = state
                    self.publish()
                    self.scheduleAutomaticRetry()
                }
            })
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == account else { return }
                self.failures = 0
                // From offline the SDK skips its server polling and syncs at once.
                try? await self.retry()
            }
        }
    }

    // Offline mode covers network loss; this restarts a sync that ended in an error or stopped on its own.
    private func scheduleAutomaticRetry() {
        guard sdkState == .error || sdkState == .terminated else {
            if sdkState == .running { failures = 0 }
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

    func retry() async throws {
        try Task.checkCancellation()
        guard let service else {
            throw MatrixServiceError.request("Still connecting. Try again in a moment.")
        }
        if let attempt {
            try await attempt.task.value
            try Task.checkCancellation()
            return
        }
        guard sdkState != .running else { return }
        let account = generation
        let id = UUID()
        // UniFFI start is not cancellable. Keep its actual await alive even if
        // a caller leaves; teardown must wait for it before stopping this SDK.
        let task = Task { @MainActor [weak self] in
            guard let self, self.generation == account else { throw CancellationError() }
            await service.start()
            guard self.generation == account else { throw CancellationError() }
        }
        attempt = Attempt(id: id, task: task)
        publish()
        let result = await task.result
        if generation == account, attempt?.id == id {
            attempt = nil
            publish()
        }
        try Task.checkCancellation()
        try result.get()
        // Only the sync observer reports Ready, once the server has actually answered.
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
        automaticRetry?.cancel()
        automaticRetry = nil
        failures = 0
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        service = nil
        client = nil
        attempt = nil
        revision = 0
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
        let (state, error): (MatrixConnectionState, String?) =
            switch sdkState {
            case .running: (.running, nil)
            case .offline: (.offline, "You’re offline. Check your connection.")
            case .terminated: (.stopped, "Disconnected. Retry to reconnect.")
            case .error: (.failed, "Couldn’t connect. Retry, or sign in again.")
            case .idle: (.idle, nil)
            case nil: (.connecting, nil)
            }
        let busy = attempt != nil
        feedback = MatrixConnectionFeedback(
            state: state, isRetrying: busy, canRetry: service != nil && !busy && state != .running,
            errorMessage: error)
        onUpdate?(feedback)
    }
}
