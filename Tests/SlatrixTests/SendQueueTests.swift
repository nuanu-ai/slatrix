import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class QueueRoom: Room, @unchecked Sendable {
    let enabled = Recorder<Bool>()
    override func enableSendQueue(enable: Bool) { enabled.append(enable) }
}

private final class QueueTimeline: Timeline, @unchecked Sendable {
    let retried = Recorder<EventOrTransactionId>()
    let aborted = Recorder<EventOrTransactionId>()
    let otherWrites = Recorder<String>()
    var retryResult = true
    var abortResult = true
    var failRetry = false
    override func retrySend(itemId: EventOrTransactionId, target: SendTarget) async throws -> Bool {
        retried.append(itemId)
        if failRetry { throw MatrixServiceError.request("original request failed") }
        return retryResult
    }
    override func abortSend(itemId: EventOrTransactionId, target: SendTarget) async throws -> Bool {
        aborted.append(itemId)
        return abortResult
    }
    override func send(msg: RoomMessageEventContentWithoutRelation) async throws -> SendHandle {
        otherWrites.append("send")
        return SendHandle(noHandle: .init())
    }
    override func redactEvent(eventOrTransactionId: EventOrTransactionId, reason: String?) async throws {
        otherWrites.append("redact")
    }
}

private let local = EventOrTransactionId.transactionId(transactionId: "local-transaction")
private let remote = EventOrTransactionId.eventId(eventId: "$remote")
private let verificationErrors: [QueueWedgeError] = [
    .insecureDevices(userDeviceMap: ["@other:example.org": ["device"]]),
    .identityViolations(users: ["@other:example.org"]),
    .crossVerificationRequired,
]

private func failure(_ error: QueueWedgeError, recoverable: Bool) throws -> MessageSendFailure {
    try #require(MessageSendFailure.failure(.sendingFailed(error: error, isRecoverable: recoverable)))
}

@MainActor
struct SendQueueTests {
    private let room = QueueRoom(noHandle: .init())
    private let timeline = QueueTimeline(noHandle: .init())

    @Test(
        "Queued and sent events are not send failures",
        arguments: [nil, EventSendState.notSentYet(progress: nil), .sent(eventId: "$sent")])
    func noFailureWithoutSendingFailed(state: EventSendState?) {
        #expect(MessageSendFailure.failure(state) == nil)
    }

    @Test(
        "Raw server and media payloads never reach the row's error text",
        arguments: [
            (QueueWedgeError.genericApiError(msg: "private-payload"), true),
            (.genericApiError(msg: "private-payload"), false),
            (.invalidMimeType(mimeType: "private-payload"), true),
        ])
    func redactsErrorPayload(error: QueueWedgeError, recoverable: Bool) throws {
        #expect(try !failure(error, recoverable: recoverable).message.contains("private-payload"))
    }

    @Test("A message that couldn't go out offline waits as pending; other failures still show")
    func offlineFailureIsPending() throws {
        let network = try failure(.genericApiError(msg: "x"), recoverable: true)
        #expect(network.shown(offline: true) == nil)
        #expect(network.shown(offline: false) == network)
        let verification = try failure(.crossVerificationRequired, recoverable: true)
        #expect(verification.shown(offline: true) == verification)
    }

    // capability: message.retry-failed
    @Test("Retrying a recoverable failure resumes the room's queue without re-sending anything")
    func recoverableRetryResumesQueue() async throws {
        let recoverable = try failure(.genericApiError(msg: "x"), recoverable: true)
        #expect(recoverable.kind == .recoverable)
        #expect(try await SendQueueActions.retry(recoverable, itemID: local, room: room, timeline: timeline))
        #expect(room.enabled.all == [true])
        #expect(timeline.retried.all.isEmpty && timeline.otherWrites.all.isEmpty)
    }

    @Test("Retrying a rejected message retries its original transaction without resuming the room")
    func rejectedRetryTargetsTransaction() async throws {
        let rejected = try failure(.genericApiError(msg: "x"), recoverable: false)
        #expect(rejected.kind == .rejected)
        _ = try await SendQueueActions.retry(rejected, itemID: local, room: room, timeline: timeline)
        #expect(timeline.retried.all == [local])
        #expect(room.enabled.all.isEmpty && timeline.otherWrites.all.isEmpty)
    }

    @Test(
        "Verification failures retry through the SDK's guarded retry even when flagged recoverable",
        arguments: verificationErrors)
    func verificationRetry(error: QueueWedgeError) async throws {
        let verification = try failure(error, recoverable: true)
        #expect(verification.kind == .verification && verification.canRetry)
        _ = try await SendQueueActions.retry(verification, itemID: local, room: room, timeline: timeline)
        #expect(timeline.retried.all == [local])
        #expect(room.enabled.all.isEmpty)
    }

    @Test(
        "Session and media failures cannot be retried and leave the queue untouched",
        arguments: [
            (QueueWedgeError.expiredAccessToken, MessageSendFailure.Kind.session),
            (.missingMediaContent, .missingMedia), (.invalidMimeType(mimeType: "x"), .invalidMedia),
        ])
    func gatedFailures(error: QueueWedgeError, kind: MessageSendFailure.Kind) async throws {
        let gated = try failure(error, recoverable: true)
        #expect(gated.kind == kind && !gated.canRetry)
        await #expect(throws: MatrixServiceError.self) {
            _ = try await SendQueueActions.retry(gated, itemID: local, room: self.room, timeline: self.timeline)
        }
        #expect(room.enabled.all.isEmpty && timeline.retried.all.isEmpty)
    }

    @Test("An event the SDK no longer has pending is never sent again as a new message")
    func noLongerPendingRetry() async throws {
        timeline.retryResult = false
        let rejected = try failure(.genericApiError(msg: "x"), recoverable: false)
        #expect(try await !SendQueueActions.retry(rejected, itemID: local, room: room, timeline: timeline))
        #expect(timeline.otherWrites.all.isEmpty)
    }

    @Test("A failing SDK retry propagates its error without a replacement send")
    func failingRetryPropagates() async throws {
        timeline.failRetry = true
        let rejected = try failure(.genericApiError(msg: "x"), recoverable: false)
        await #expect(throws: MatrixServiceError.self) {
            _ = try await SendQueueActions.retry(rejected, itemID: local, room: self.room, timeline: self.timeline)
        }
        #expect(timeline.otherWrites.all.isEmpty)
    }

    @Test("Remote events cannot be retried or cancelled as local echoes")
    func remoteEventsRejected() async throws {
        let recoverable = try failure(.genericApiError(msg: "x"), recoverable: true)
        #expect(try await !SendQueueActions.retry(recoverable, itemID: remote, room: room, timeline: timeline))
        #expect(try await !SendQueueActions.cancel(itemID: remote, timeline: timeline))
        #expect(room.enabled.all.isEmpty && timeline.aborted.all.isEmpty)
    }

    // capability: message.retry-failed
    @Test("Cancelling aborts the original local transaction")
    func cancelAborts() async throws {
        #expect(try await SendQueueActions.cancel(itemID: local, timeline: timeline))
        #expect(timeline.aborted.all == [local])
    }

    @Test("A failed abort never falls back to redacting or re-sending")
    func failedAbortHasNoFallback() async throws {
        timeline.abortResult = false
        #expect(try await !SendQueueActions.cancel(itemID: local, timeline: timeline))
        #expect(timeline.otherWrites.all.isEmpty)
    }
}

@MainActor
struct SendQueueStaleMessageTests {
    let stale = ChatMessage(
        id: "local-transaction", roomID: "!old:example.org", senderID: "@me:example.org", senderName: "Me",
        body: "Pending", timestamp: Date(), sendState: "failed")

    @Test("Retry and cancel reject a message from a room that is no longer selected", arguments: [true, false])
    func roomSwitched(retry: Bool) async {
        let service = MatrixService()
        service.configureMessageActionsForChecks(
            client: FakeClient(), main: nil, thread: nil, rootID: nil, sessionID: UUID(), selectionID: UUID(),
            threadID: UUID())
        service.selectedRoomID = "!new:example.org"
        await #expect(throws: MatrixServiceError.self) {
            if retry { try await service.retryMessage(stale) } else { _ = try await service.cancelMessage(stale) }
        }
    }

    @Test("Retry and cancel reject a stale local echo after sign-out", arguments: [true, false])
    func signedOut(retry: Bool) async {
        let service = MatrixService()
        service.selectedRoomID = stale.roomID
        await #expect(throws: (any Error).self) {
            if retry { try await service.retryMessage(stale) } else { _ = try await service.cancelMessage(stale) }
        }
        #expect(service.pendingSendActions.isEmpty && service.sendFailures.isEmpty)
    }
}
