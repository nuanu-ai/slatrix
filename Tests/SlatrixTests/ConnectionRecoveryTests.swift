import AppKit
import Foundation
import MatrixRustSDK
import Network
import Testing

@testable import Slatrix

/// Records the SDK's switch for every room's send queue.
private final class SendQueueClient: Client, @unchecked Sendable {
    let enabled = Recorder<Bool>()
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func enableAllSendQueues(enable: Bool) async { enabled.append(enable) }

    /// A room whose queue the SDK stopped after a failed send.
    let stopped = StoppedQueueRoom()
    private let updates = Recorder<SendQueueRoomUpdateListener>()
    func failSend(roomID: String, transactionID: String = "txn-1", recoverable: Bool = true) {
        emitQueue(
            roomID: roomID,
            update: .sendError(
                transactionId: transactionID, error: .genericApiError(msg: "502"), isRecoverable: recoverable))
    }
    func emitQueue(roomID: String, update: RoomSendQueueUpdate) {
        for listener in updates.all { listener.onUpdate(roomId: roomID, update: update) }
    }
    override func subscribeToSendQueueUpdates(listener: SendQueueRoomUpdateListener) async throws -> TaskHandle {
        updates.append(listener)
        return FakeCancellableHandle(noHandle: .init())
    }
    override func getRoom(roomId: String) throws -> Room? { roomId == "!room" ? stopped : nil }

    /// Changes the server refused, still at the head of their rooms' queues, and each time the app looked for them.
    private let lock = NSLock()
    private var refused: [RefusedChange] = []
    var wedged: [RefusedChange] {
        get { lock.withLock { refused } }
        set { lock.withLock { refused = newValue } }
    }
    let looks = Recorder<Void>()
    override func abortRefusedChanges() async throws -> [RefusedChange] {
        looks.append(())
        return lock.withLock {
            defer { refused = [] }
            return refused
        }
    }
}

final class StoppedQueueRoom: Room, @unchecked Sendable {
    let enabled = Recorder<Bool>()
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func isSendQueueEnabled() -> Bool { enabled.all.last ?? false }
    override func enableSendQueue(enable: Bool) { enabled.append(enable) }
}

private let wifiRoute = NetworkRoute.online(interface: 4, gateways: [])

@MainActor private func onlineRecovery(wakeNotifications: NotificationCenter = NotificationCenter())
    -> ConnectionRecovery
{
    ConnectionRecovery(networkChanges: { AsyncStream { $0.yield(wifiRoute) } }, wakeNotifications: wakeNotifications)
}

@MainActor
struct ConnectionRecoveryTests {
    // capability: message.send-offline
    @Test("Messages the SDK paused while offline go out when the connection returns, without a click")
    func reconnectResumesSending() async throws {
        let recovery = onlineRecovery()
        let service = FakeSyncService(state: .offline)
        let client = SendQueueClient()
        try await recovery.attach(service, client: client) { _ in }
        service.emit(.running)
        #expect(await eventually { client.enabled.all == [true] })
        await recovery.stop()
    }

    @Test("A connection that drops before the SDK can resume sending leaves queues paused")
    func offlineBeforeQueuedResume() async throws {
        let recovery = onlineRecovery()
        let service = FakeSyncService()
        service.confirmsSync = false
        let client = SendQueueClient()
        var connected = false
        var queueAtDrop: [Bool]?
        try await recovery.attach(service, client: client) { feedback in
            if feedback.state == .running { connected = true }
            if connected && feedback.state == .offline && queueAtDrop == nil { queueAtDrop = client.enabled.all }
        }
        service.emit(.running)
        try #require(await eventually { recovery.feedback.state == .connecting })
        service.roomSync.emit(.running)
        service.emit(.offline)
        try #require(await eventually { queueAtDrop != nil })
        await drainMainActor()
        #expect(client.enabled.all == queueAtDrop)
        await recovery.stop()
    }

    @Test("A room whose sending stopped on a server error resumes by itself while connected, without a restart")
    func failedSendResumes() async throws {
        let recovery = ConnectionRecovery(
            networkChanges: { AsyncStream { $0.yield(wifiRoute) } }, wakeNotifications: NotificationCenter(),
            waitToResumeSending: { _ in })
        let service = FakeSyncService(state: .running)
        let client = SendQueueClient()
        try await recovery.attach(service, client: client) { _ in }
        #expect(await eventually { recovery.feedback.state == .running })
        client.failSend(roomID: "!room")
        #expect(await eventually { client.stopped.enabled.all == [true] })
        await recovery.stop()
    }

    @Test("A delayed room retry leaves its queue paused when the connection has since dropped")
    func offlineBeforeRoomRetry() async throws {
        var releaseTimer: CheckedContinuation<Void, Never>?
        var timerFired = false
        let recovery = ConnectionRecovery(
            networkChanges: { AsyncStream { $0.yield(wifiRoute) } }, wakeNotifications: NotificationCenter(),
            waitToResumeSending: { _ in
                await withCheckedContinuation { releaseTimer = $0 }
                timerFired = true
            })
        let service = FakeSyncService(state: .running)
        let client = SendQueueClient()
        try await recovery.attach(service, client: client) { _ in }
        try #require(await eventually { recovery.feedback.state == .running })
        client.failSend(roomID: "!room")
        try #require(await eventually { releaseTimer != nil })
        service.emit(.offline)
        try #require(await eventually { recovery.feedback.state == .offline })

        releaseTimer?.resume()
        try #require(await eventually { timerFired })
        await drainMainActor()
        #expect(client.stopped.enabled.all.isEmpty)
        await recovery.stop()
    }

    @Test(
        "A sync error restarts sync without the user pressing Retry", arguments: [SyncServiceState.error, .terminated])
    func restartsAfterFailure(state: SyncServiceState) async throws {
        let recovery = onlineRecovery()
        let service = FakeSyncService(state: .running)
        try await recovery.attach(service) { _ in }
        service.emit(state)
        #expect(await eventually { service.startCount == 1 && recovery.feedback.state == .running })
        await recovery.stop()
    }

    @Test("Waking the Mac restarts an offline sync immediately")
    func restartsOnWake() async throws {
        let notifications = NotificationCenter()
        let recovery = onlineRecovery(wakeNotifications: notifications)
        let service = FakeSyncService(state: .offline)
        try await recovery.attach(service) { _ in }
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await eventually { service.startCount == 1 && recovery.feedback.state == .running })
        await recovery.stop()
    }

    @Test("Waking a sync that still reports running resumes messages paused by a broken connection")
    func wakesStaleRunningSync() async throws {
        let notifications = NotificationCenter()
        let recovery = onlineRecovery(wakeNotifications: notifications)
        let service = FakeSyncService(state: .running)
        let client = SendQueueClient()
        try await recovery.attach(service, client: client) { _ in }
        #expect(await eventually { client.enabled.all.last == true })
        await client.enableAllSendQueues(enable: false)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await eventually { client.enabled.all.last == true })
        await recovery.stop()
    }

    // capability: message.delete
    @Test("A change refused while offline is cancelled once sending resumes on reconnecting")
    func reconnectCancelsRefusedChanges() async throws {
        let network = AsyncStream<NetworkRoute>.makeStream()
        network.continuation.yield(wifiRoute)
        let recovery = ConnectionRecovery(networkChanges: { network.stream })
        let client = SendQueueClient()
        let refused = RefusedChanges(client: client) { _ in }
        try await recovery.attach(
            FakeSyncService(state: .running), client: client, onSendingResumed: { refused.cancel() },
            onUpdate: { _ in })
        try #require(await eventually { !client.looks.all.isEmpty })

        network.continuation.yield(.offline)
        try #require(await eventually { recovery.feedback.state == .offline })
        await client.enableAllSendQueues(enable: false)
        client.wedged = [RefusedChange(roomId: "!room", eventId: "$refused", kind: .redaction)]
        network.continuation.yield(wifiRoute)
        #expect(await eventually { client.enabled.all.last == true && client.wedged.isEmpty })
        await recovery.stop()
        network.continuation.finish()
    }

    @Test("Network loss says offline, and a returned network reconnects without a click")
    func networkLossAndReturn() async throws {
        let network = AsyncStream<NetworkRoute>.makeStream()
        let recovery = ConnectionRecovery(networkChanges: { network.stream })
        let service = FakeSyncService(state: .running)
        try await recovery.attach(service) { _ in }
        #expect(await eventually { recovery.feedback.state == .running })
        network.continuation.yield(.offline)
        #expect(await eventually { recovery.feedback.state == .offline })
        network.continuation.yield(wifiRoute)
        #expect(await eventually { recovery.feedback.state == .running })
        await recovery.stop()
        network.continuation.finish()
    }

    @Test(
        "A new interface or gateway releases a stale sync and resumes messages without an offline notification",
        arguments: [
            NetworkRoute.online(interface: 7, gateways: []),
            .online(interface: 4, gateways: [.hostPort(host: "192.0.2.1", port: .any)]),
        ])
    func routeHandoffResumesSending(newRoute: NetworkRoute) async throws {
        let network = AsyncStream<NetworkRoute>.makeStream()
        network.continuation.yield(wifiRoute)
        let recovery = ConnectionRecovery(networkChanges: { network.stream })
        let service = FakeSyncService(state: .running)
        let client = SendQueueClient()
        try await recovery.attach(service, client: client) { _ in }
        try #require(await eventually { client.enabled.all.last == true })
        await client.enableAllSendQueues(enable: false)

        network.continuation.yield(newRoute)
        #expect(await eventually { client.enabled.all.last == true && recovery.feedback.state == .running })
        await recovery.stop()
        network.continuation.finish()
    }

    @Test("A path update that keeps the network leaves a running sync alone")
    func steadyNetworkKeepsSync() async throws {
        let network = AsyncStream<NetworkRoute>.makeStream()
        let recovery = ConnectionRecovery(networkChanges: { network.stream })
        let service = FakeSyncService(state: .running)
        try await recovery.attach(service) { _ in }
        network.continuation.yield(wifiRoute)
        network.continuation.yield(wifiRoute)
        network.continuation.yield(.offline)
        #expect(await eventually { recovery.feedback.state == .offline })
        #expect(service.stopCount == 0)
        await recovery.stop()
        network.continuation.finish()
    }

    enum Interruption: CaseIterable {
        case noNetwork, wifi, ethernet, wake, offlineSync, failedSync, endedSync, oldReply
    }

    @Test(
        "A network restored while an earlier SDK start is suspended still resumes the queue",
        arguments: Interruption.allCases, Interruption.allCases)
    func handoffDuringStart(first: Interruption, second: Interruption) async throws {
        let network = AsyncStream<NetworkRoute>.makeStream()
        let wake = NotificationCenter()
        let recovery = ConnectionRecovery(networkChanges: { network.stream }, wakeNotifications: wake)
        let service = FakeSyncService(state: .running)
        let client = SendQueueClient()
        let ethernet = NetworkRoute.online(interface: 7, gateways: [])
        network.continuation.yield(wifiRoute)
        try await recovery.attach(service, client: client) { _ in }
        try #require(await eventually { client.enabled.all.last == true })

        let oldReply = service.roomSync.pendingUpdate(.running)
        service.startGate.arm()
        defer { service.startGate.release() }
        wake.post(name: NSWorkspace.didWakeNotification, object: nil)
        try #require(await eventually { service.startGate.isWaiting })
        for event in [first, second] {
            switch event {
            case .noNetwork: network.continuation.yield(.offline)
            case .wifi: network.continuation.yield(wifiRoute)
            case .ethernet: network.continuation.yield(ethernet)
            case .wake: wake.post(name: NSWorkspace.didWakeNotification, object: nil)
            case .offlineSync: service.emit(.offline)
            case .failedSync: service.emit(.error)
            case .endedSync: service.emit(.terminated)
            case .oldReply: oldReply()
            }
        }

        network.continuation.yield(.offline)
        try #require(await eventually { recovery.feedback.errorMessage == "You’re offline" })
        await client.enableAllSendQueues(enable: false)
        network.continuation.yield(ethernet)
        try #require(await eventually { recovery.feedback.errorMessage != "You’re offline" })
        await drainMainActor()
        service.startGate.release()
        #expect(
            await eventually {
                recovery.feedback.state == .running && !recovery.feedback.isRetrying && client.enabled.all.last == true
            })
        await recovery.stop()
        network.continuation.finish()
    }

    enum ReplyTiming: CaseIterable { case offline, stopping, restarted }

    @Test(
        "A room reply from the old connection cannot resume sends before the new connection answers",
        arguments: [RoomListServiceState.settingUp, .recovering, .running], ReplyTiming.allCases)
    func lateRoomSyncDuringNetworkLoss(response: RoomListServiceState, timing: ReplyTiming) async throws {
        let network = AsyncStream<NetworkRoute>.makeStream()
        let recovery = ConnectionRecovery(networkChanges: { network.stream })
        let service = FakeSyncService(state: .running)
        let client = SendQueueClient()
        try await recovery.attach(service, client: client) { _ in }
        try #require(await eventually { client.enabled.all.last == true })

        let deliverOldReply = service.roomSync.pendingUpdate(response)
        network.continuation.yield(.offline)
        try #require(await eventually { recovery.feedback.state == .offline })
        await client.enableAllSendQueues(enable: false)
        service.confirmsSync = false
        if timing == .offline {
            deliverOldReply()
            await drainMainActor()
        }
        if timing == .stopping { service.stopGate.arm() }
        network.continuation.yield(wifiRoute)
        if timing == .stopping {
            try #require(await eventually { service.stopGate.isWaiting })
            deliverOldReply()
            await drainMainActor()
            service.stopGate.release()
        }
        try #require(await eventually { service.startCount > 0 && !recovery.feedback.isRetrying })
        if timing == .restarted {
            deliverOldReply()
            await drainMainActor()
        }

        #expect(recovery.feedback.state != .running && client.enabled.all.last == false)
        service.roomSync.emit(.running)
        #expect(await eventually { client.enabled.all.last == true && recovery.feedback.state == .running })
        await recovery.stop()
        network.continuation.finish()
    }

    @Test("A slow SDK start cannot block reporting that the network disappeared")
    func networkLossDuringStart() async throws {
        let network = AsyncStream<NetworkRoute>.makeStream()
        network.continuation.yield(wifiRoute)
        let recovery = ConnectionRecovery(networkChanges: { network.stream })
        let service = FakeSyncService()
        service.startGate.arm()
        try await recovery.attach(service) { _ in }
        let starting = Task { try await recovery.retry() }
        #expect(await eventually { service.startGate.isWaiting })
        network.continuation.yield(.offline)
        #expect(await eventually { recovery.feedback.errorMessage == "You’re offline" })
        service.startGate.release()
        try await starting.value
        await recovery.stop()
        network.continuation.finish()
    }

    @Test("Unrecoverable send errors do not increment room backoff or schedule a queue resume")
    func unrecoverableSendErrorSkipsBackoff() async throws {
        var observedFailures: [Int] = []
        let recovery = ConnectionRecovery(
            networkChanges: { AsyncStream { $0.yield(wifiRoute) } }, wakeNotifications: NotificationCenter(),
            waitToResumeSending: { observedFailures.append($0) })
        let service = FakeSyncService(state: .running)
        let client = SendQueueClient()
        try await recovery.attach(service, client: client) { _ in }
        try #require(await eventually { recovery.feedback.state == .running })

        client.failSend(roomID: "!room", transactionID: "t1", recoverable: false)
        client.failSend(roomID: "!room", transactionID: "t2", recoverable: false)
        await drainMainActor()
        #expect(observedFailures.isEmpty && client.stopped.enabled.all.isEmpty)

        client.failSend(roomID: "!room", transactionID: "t3", recoverable: true)
        #expect(await eventually { observedFailures == [0] && client.stopped.enabled.all == [true] })
        await recovery.stop()
    }

    @Test("A sent event resets per-room send queue backoff")
    func sentEventResetsBackoff() async throws {
        var observedFailures: [Int] = []
        let recovery = ConnectionRecovery(
            networkChanges: { AsyncStream { $0.yield(wifiRoute) } }, wakeNotifications: NotificationCenter(),
            waitToResumeSending: { observedFailures.append($0) })
        let service = FakeSyncService(state: .running)
        let client = SendQueueClient()
        try await recovery.attach(service, client: client) { _ in }
        try #require(await eventually { recovery.feedback.state == .running })

        client.failSend(roomID: "!room", transactionID: "t1", recoverable: true)
        #expect(await eventually { observedFailures == [0] })
        client.stopped.enableSendQueue(enable: false)
        client.failSend(roomID: "!room", transactionID: "t1", recoverable: true)
        #expect(await eventually { observedFailures == [0, 1] })

        client.emitQueue(roomID: "!room", update: .sentEvent(transactionId: "t1", eventId: "$sent"))
        await drainMainActor()
        client.stopped.enableSendQueue(enable: false)
        client.failSend(roomID: "!room", transactionID: "t2", recoverable: true)
        #expect(await eventually { observedFailures == [0, 1, 0] })
        await recovery.stop()
    }

    @Test("Cancelling a failed local event cancels its backoff timer and immediately re-enables the room queue")
    func cancelledEventResumesRoomImmediately() async throws {
        var releaseTimer: CheckedContinuation<Void, Never>?
        let recovery = ConnectionRecovery(
            networkChanges: { AsyncStream { $0.yield(wifiRoute) } }, wakeNotifications: NotificationCenter(),
            waitToResumeSending: { _ in await withCheckedContinuation { releaseTimer = $0 } })
        let service = FakeSyncService(state: .running)
        let client = SendQueueClient()
        try await recovery.attach(service, client: client) { _ in }
        try #require(await eventually { recovery.feedback.state == .running })

        client.failSend(roomID: "!room", transactionID: "t1", recoverable: true)
        try #require(await eventually { releaseTimer != nil })
        client.emitQueue(roomID: "!room", update: .cancelledLocalEvent(transactionId: "t1"))
        #expect(await eventually { client.stopped.enabled.all == [true] })
        releaseTimer?.resume()
        await recovery.stop()
    }

    @Test("Cancelling a follower message leaves an earlier failed message's backoff and paused queue intact")
    func cancellingFollowerLeavesFailureBackoffIntact() async throws {
        var timerCount = 0
        var releaseTimer: CheckedContinuation<Void, Never>?
        let recovery = ConnectionRecovery(
            networkChanges: { AsyncStream { $0.yield(wifiRoute) } }, wakeNotifications: NotificationCenter(),
            waitToResumeSending: { _ in
                timerCount += 1
                await withCheckedContinuation { releaseTimer = $0 }
            })
        let service = FakeSyncService(state: .running)
        let client = SendQueueClient()
        try await recovery.attach(service, client: client) { _ in }
        try #require(await eventually { recovery.feedback.state == .running })

        client.failSend(roomID: "!room", transactionID: "t1", recoverable: true)
        try #require(await eventually { releaseTimer != nil })

        // Follower t2 is cancelled while t1 is still failed: queue must stay paused and backoff intact.
        client.emitQueue(roomID: "!room", update: .cancelledLocalEvent(transactionId: "t2"))
        await drainMainActor()
        #expect(client.stopped.enabled.all.isEmpty && timerCount == 1)

        // Now cancelling the blocking failure t1 itself unblocks the room queue.
        client.emitQueue(roomID: "!room", update: .cancelledLocalEvent(transactionId: "t1"))
        #expect(await eventually { client.stopped.enabled.all == [true] })
        releaseTimer?.resume()
        await recovery.stop()
    }

    @Test("Health probe rejects reverse-proxy 502/503 responses and restarts sync")
    func healthProbeRejectsHTTP502() async throws {
        let url = URL(string: "http://127.0.0.1/versions")!
        let ok = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let badGateway = try #require(HTTPURLResponse(url: url, statusCode: 502, httpVersion: nil, headerFields: nil))
        let unavailable = try #require(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil))
        #expect(ConnectionRecovery.isHealthyHTTPResponse(ok))
        #expect(!ConnectionRecovery.isHealthyHTTPResponse(badGateway))
        #expect(!ConnectionRecovery.isHealthyHTTPResponse(unavailable))

        // Verify the real URLSession probe treats a loopback HTTP 502 server as unhealthy and restarts sync.
        let listener = try NWListener(using: .tcp)
        let queue = DispatchQueue(label: "HealthProbe502")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let response = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        defer { listener.cancel() }

        let recovery = ConnectionRecovery(
            networkChanges: { AsyncStream { $0.yield(wifiRoute) } }, wakeNotifications: NotificationCenter(),
            waitToResumeSending: { _ in try await Task.sleep(for: .seconds(60)) },
            healthCheckInterval: .zero)
        let service = FakeSyncService(state: .running)
        let client = SendQueueClient()
        try await recovery.attach(service, client: client, homeserverURL: "http://127.0.0.1:\(port)") { _ in }
        try #require(await eventually { recovery.feedback.state == .running })

        client.failSend(roomID: "!room", transactionID: "t1", recoverable: true)
        #expect(await eventually(timeout: .seconds(5)) { service.stopCount == 1 && service.startCount == 1 })
        await recovery.stop()
    }

    @Test("System sleep stops sync cleanly without retrying until wake restarts it")
    func sleepStopsAndWakeRestarts() async throws {
        let notifications = NotificationCenter()
        let recovery = onlineRecovery(wakeNotifications: notifications)
        let service = FakeSyncService(state: .running)
        try await recovery.attach(service) { _ in }
        try #require(await eventually { recovery.feedback.state == .running })

        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(await eventually { service.stopCount == 1 })
        #expect(recovery.feedback.errorMessage == nil)
        // A sync error while asleep must not restart sync before wake.
        service.emit(.error)
        await drainMainActor()
        #expect(service.startCount == 0)

        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await eventually { service.startCount == 1 && recovery.feedback.state == .running })
        await recovery.stop()
    }

    @Test("System sleep firing right after retry() starts never deadlocks recovery or teardown")
    func sleepImmediatelyAfterRetryDoesNotDeadlock() async throws {
        let notifications = NotificationCenter()
        let recovery = onlineRecovery(wakeNotifications: notifications)
        let service = FakeSyncService(state: .offline)
        try await recovery.attach(service) { _ in }

        // Queue retry() #1 and willSleep #2 on MainActor so pauseForSleep runs in the exact gap between
        // retry() publishing `attempt` and its inner Task body starting (#3).
        let retrying = Task { @MainActor in try? await recovery.retry() }
        let sleeper = Task { @MainActor in
            notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        }
        await sleeper.value

        var stopped = false
        let stopping = Task {
            await recovery.stop()
            stopped = true
        }
        let finished = await eventually(timeout: .seconds(2)) { stopped }
        #expect(finished, "retry() and pauseForSleep() deadlocked waiting on each other")
        if finished {
            await retrying.value
            await stopping.value
        }
    }

    @Test("A brief offline blip during SDK start never leaves room sync responses unobserved")
    func offlineDuringStartKeepsResponseObserver() async throws {
        let network = AsyncStream<NetworkRoute>.makeStream()
        network.continuation.yield(wifiRoute)
        let recovery = ConnectionRecovery(networkChanges: { network.stream })
        let service = FakeSyncService(state: .offline)
        service.confirmsSync = false
        service.startGate.arm()
        try await recovery.attach(service) { _ in }

        let starting = Task { try await recovery.retry() }
        try #require(await eventually { service.startGate.isWaiting })
        network.continuation.yield(.offline)
        try #require(await eventually { recovery.feedback.state == .offline })
        network.continuation.yield(wifiRoute)
        await drainMainActor()
        service.startGate.release()
        try await starting.value
        try #require(await eventually { !recovery.feedback.isRetrying })

        service.roomSync.emit(.running)
        #expect(await eventually { recovery.feedback.state == .running })
        await recovery.stop()
        network.continuation.finish()
    }

    @Test("A recoverable send failure on a blackholed socket triggers a rate-limited health check and restarts sync")
    func blackholedSocketHealthCheckRestartsSync() async throws {
        var probes = 0
        var healthy = false
        let recovery = ConnectionRecovery(
            networkChanges: { AsyncStream { $0.yield(wifiRoute) } }, wakeNotifications: NotificationCenter(),
            waitToResumeSending: { _ in try await Task.sleep(for: .seconds(60)) },
            checkHealth: {
                probes += 1
                return healthy
            }, healthCheckInterval: .seconds(60))
        let service = FakeSyncService(state: .running)
        let client = SendQueueClient()
        try await recovery.attach(service, client: client) { _ in }
        try #require(await eventually { recovery.feedback.state == .running })

        client.failSend(roomID: "!room", transactionID: "t1", recoverable: true)
        #expect(await eventually { probes == 1 && service.stopCount == 1 && service.startCount == 1 })
        #expect(await eventually { recovery.feedback.state == .running })

        // Rate-limited: a second failure immediately after does not re-probe or restart.
        healthy = true
        client.failSend(roomID: "!room", transactionID: "t2", recoverable: true)
        await drainMainActor()
        #expect(probes == 1 && service.stopCount == 1)
        await recovery.stop()
    }
}

@MainActor
struct ConnectionRecoveryOwnershipTests {
    @Test("Starting sync does not claim connected before the server answers")
    func waitsForServerResponse() async throws {
        let recovery = onlineRecovery()
        let service = FakeSyncService()
        service.confirmsSync = false
        try await recovery.attach(service) { _ in }
        try await recovery.retry()
        await drainMainActor()
        #expect(recovery.feedback.state == .connecting)
        service.roomSync.emit(.settingUp)
        #expect(await eventually { recovery.feedback.state == .running })
        await recovery.stop()
    }

    @Test("Only an SDK state reports sync as running, never start returning")
    func startReturningIsNotRunning() async throws {
        let recovery = onlineRecovery()
        let service = FakeSyncService(state: .offline)
        service.stateOnStart = nil
        try await recovery.attach(service) { _ in }
        try await recovery.retry()
        #expect(service.startCount == 1 && recovery.feedback.state == .offline && recovery.feedback.canRetry)
        await recovery.stop()
    }

    @Test("Concurrent retries share one SDK start")
    func concurrentRetriesShareStart() async throws {
        let recovery = onlineRecovery()
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
        let recovery = onlineRecovery()
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
        let recovery = onlineRecovery()
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
