import AppKit
import MatrixRustSDK
import Testing

@testable import Slatrix

/// Records the SDK's switch for every room's send queue.
private final class SendQueueClient: Client, @unchecked Sendable {
    let enabled = Recorder<Bool>()
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func enableAllSendQueues(enable: Bool) async { enabled.append(enable) }
}

@MainActor
struct ConnectionRecoveryTests {
    // capability: message.send-offline
    @Test("Messages the SDK paused while offline go out when the connection returns, without a click")
    func reconnectResumesSending() async throws {
        let recovery = ConnectionRecovery()
        let service = FakeSyncService(state: .offline)
        let client = SendQueueClient()
        try await recovery.attach(service, client: client) { _ in }
        service.emit(.running)
        #expect(await eventually { client.enabled.all == [true] })
        await recovery.stop()
    }

    @Test(
        "A sync error restarts sync without the user pressing Retry", arguments: [SyncServiceState.error, .terminated])
    func restartsAfterFailure(state: SyncServiceState) async throws {
        let recovery = ConnectionRecovery()
        let service = FakeSyncService(state: .running)
        try await recovery.attach(service) { _ in }
        service.emit(state)
        #expect(await eventually { service.startCount == 1 && recovery.feedback.state == .running })
        await recovery.stop()
    }

    @Test("Waking the Mac restarts an offline sync immediately")
    func restartsOnWake() async throws {
        let recovery = ConnectionRecovery()
        let service = FakeSyncService(state: .offline)
        try await recovery.attach(service) { _ in }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await eventually { service.startCount == 1 && recovery.feedback.state == .running })
        await recovery.stop()
    }
}

@MainActor
struct ConnectionRecoveryOwnershipTests {
    @Test("Only an SDK state reports sync as running, never start returning")
    func startReturningIsNotRunning() async throws {
        let recovery = ConnectionRecovery()
        let service = FakeSyncService(state: .offline)
        service.stateOnStart = nil
        try await recovery.attach(service) { _ in }
        try await recovery.retry()
        #expect(service.startCount == 1 && recovery.feedback.state == .offline && recovery.feedback.canRetry)
        await recovery.stop()
    }

    @Test("Concurrent retries share one SDK start")
    func concurrentRetriesShareStart() async throws {
        let recovery = ConnectionRecovery()
        let service = FakeSyncService(state: .offline)
        service.startGate.arm()
        try await recovery.attach(service) { _ in }
        let first = Task { try await recovery.retry() }
        #expect(await eventually { service.startGate.isWaiting })
        let second = Task { try await recovery.retry() }
        #expect(recovery.feedback.isRetrying && !recovery.feedback.canRetry)
        service.startGate.release()
        try await first.value
        try await second.value
        #expect(service.startCount == 1 && recovery.feedback.state == .running)
        await recovery.stop()
    }

    @Test("Stopping waits for an in-flight start, then stops the SDK and ignores its late states")
    func stopWaitsForStart() async throws {
        let recovery = ConnectionRecovery()
        let service = FakeSyncService(state: .offline)
        service.startGate.arm()
        var published = 0
        try await recovery.attach(service) { _ in published += 1 }
        let attempt = Task { try await recovery.retry() }
        #expect(await eventually { service.startGate.isWaiting })
        let stopping = Task { await recovery.stop() }
        #expect(await eventually { recovery.feedback.state == .idle })
        #expect(service.stopCount == 0)
        let before = published
        service.emit(.running)
        service.startGate.release()
        await stopping.value
        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(service.stopCount == 1 && published == before && recovery.feedback.state == .idle)
        await #expect(throws: (any Error).self) { try await recovery.retry() }
    }

    @Test("A newer attachment owns retries and ignores the previous service")
    func newerAttachmentWins() async throws {
        let recovery = ConnectionRecovery()
        let old = FakeSyncService(state: .offline)
        let current = FakeSyncService(state: .offline)
        try await recovery.attach(old) { _ in }
        try await recovery.attach(current) { _ in }
        old.emit(.running)
        try await recovery.retry()
        #expect(old.startCount == 0 && current.startCount == 1 && recovery.feedback.state == .running)
        await recovery.stop()
    }
}
