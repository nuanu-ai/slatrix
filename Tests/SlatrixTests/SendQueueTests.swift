import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class QueueRoom: Room, @unchecked Sendable {
    let enabled = Recorder<Bool>()
    var queueEnabled = false
    override func isSendQueueEnabled() -> Bool { queueEnabled }
    override func enableSendQueue(enable: Bool) {
        queueEnabled = enable
        enabled.append(enable)
    }
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

    @Test("A file too big for the server says so and offers only Delete, since sending it again can't work")
    func fileTooLarge() throws {
        let tooLarge = try failure(
            .genericApiError(
                msg: "The provided media is too large to upload. Maximum upload length is 1 bytes, tried to upload 2"
            ),
            recoverable: false)
        #expect(tooLarge.message == "This file is bigger than the server accepts. Delete it to send the rest.")
        #expect(!tooLarge.canRetry)
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

    @Test(
        "Cancelling a failed message re-enables a paused room queue only while connected",
        arguments: [true, false])
    func cancelUnblocksQueueOnlyWhenConnected(connected: Bool) async throws {
        room.queueEnabled = false
        #expect(
            try await SendQueueActions.cancel(itemID: local, room: room, timeline: timeline, resumeQueue: connected))
        #expect(room.enabled.all == (connected ? [true] : []))
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
        let service = MatrixService.scratch()
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
        let service = MatrixService.scratch()
        service.selectedRoomID = stale.roomID
        await #expect(throws: (any Error).self) {
            if retry { try await service.retryMessage(stale) } else { _ = try await service.cancelMessage(stale) }
        }
        #expect(service.pendingSendActions.isEmpty && service.sendFailures.isEmpty)
    }

    @Test("Global send-queue tracking surfaces failed background rooms and counts messages queued for reconnect")
    func globalSendQueueVisibility() {
        let service = MatrixService.scratch()
        service.applyConnection(
            MatrixConnectionFeedback(state: .running, isRetrying: false, canRetry: false, errorMessage: nil))

        service.handleSendQueueUpdate(roomID: "!bg:example.org", update: .newLocalEvent(transactionId: "t1"))
        service.handleSendQueueUpdate(roomID: "!other:example.org", update: .newLocalEvent(transactionId: "t2"))
        #expect(service.queuedSendCount == 2 && service.failedSendRoomIDs.isEmpty)

        // Recoverable failure while connected flags the background room.
        service.handleSendQueueUpdate(
            roomID: "!bg:example.org",
            update: .sendError(transactionId: "t1", error: .genericApiError(msg: "502"), isRecoverable: true))
        #expect(service.failedSendRoomIDs == ["!bg:example.org"] && service.queuedSendCount == 2)

        // Going offline suppresses the recoverable failure indicator while keeping queued count accurate.
        service.applyConnection(
            MatrixConnectionFeedback(
                state: .offline, isRetrying: false, canRetry: false, errorMessage: ConnectionHealth.offline.label))
        #expect(service.failedSendRoomIDs.isEmpty && service.queuedSendCount == 2)

        // An unrecoverable failure still flags its room even while offline and does not count as auto-sending on reconnect.
        service.handleSendQueueUpdate(
            roomID: "!other:example.org",
            update: .sendError(transactionId: "t2", error: .invalidMimeType(mimeType: "x"), isRecoverable: false))
        #expect(service.failedSendRoomIDs == ["!other:example.org"] && service.queuedSendCount == 1)

        // Cancelling or sending clears both pending count and room warning.
        service.handleSendQueueUpdate(roomID: "!other:example.org", update: .cancelledLocalEvent(transactionId: "t2"))
        service.handleSendQueueUpdate(
            roomID: "!bg:example.org", update: .sentEvent(transactionId: "t1", eventId: "$sent"))
        #expect(service.failedSendRoomIDs.isEmpty && service.queuedSendCount == 0)
    }

    @Test("Recoverable failures are suppressed while reconnecting, not only while offline")
    func recoverableFailuresSuppressedWhileReconnecting() {
        let service = MatrixService.scratch()
        for state in [MatrixConnectionState.offline, .connecting, .stopped, .failed] {
            service.applyConnection(
                MatrixConnectionFeedback(state: state, isRetrying: false, canRetry: false, errorMessage: nil))
            #expect(service.suppressesRecoverableSendFailures)
        }
        service.applyConnection(
            MatrixConnectionFeedback(state: .running, isRetrying: false, canRetry: false, errorMessage: nil))
        #expect(!service.suppressesRecoverableSendFailures)
    }

    @Test("Retrying a failed message immediately hides its red failure until it fails again or resolves")
    func retryImmediatelySuppressesFailure() async throws {
        let f = ActionFixture()
        let service = f.service
        f.room.enableSendQueue(enable: false)
        service.applyConnection(
            MatrixConnectionFeedback(state: .running, isRetrying: false, canRetry: false, errorMessage: nil))
        let failedEvent = EventTimelineItem(
            isRemote: false, eventOrTransactionId: .transactionId(transactionId: "tx1"),
            sender: f.userID, senderProfile: .unavailable, forwarder: nil, forwarderProfile: nil,
            isOwn: true, isEditable: true,
            content: .msgLike(
                content: MsgLikeContent(
                    kind: .message(
                        content: MessageContent(
                            msgType: .text(content: TextMessageContent(body: "Hi", formatted: nil)), body: "Hi",
                            isEdited: false, mentions: nil)),
                    inReplyTo: nil, threadRoot: nil, threadSummary: nil)),
            reactions: [], eventTypeRaw: "m.room.message", timestamp: 1_000,
            localSendState: .sendingFailed(error: .genericApiError(msg: "502"), isRecoverable: true),
            editSendState: nil, redactionSendState: nil, localCreatedAt: nil, readReceipts: [:], origin: nil,
            canBeRepliedTo: true, lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
        service.projectMediaCaptionForChecks([FakeTimelineItem(failedEvent)], roomID: f.roomID, inThread: false)
        let message = try #require(service.messages.first)
        let key = SendQueueMessageKey(roomID: f.roomID, messageID: "tx1")
        #expect(service.displayedSendFailure(for: key) != nil)

        try await service.retryMessage(message)
        #expect(service.displayedSendFailure(for: key) == nil)
        #expect(service.retryingSendKeys.contains(key))

        service.handleSendQueueUpdate(
            roomID: f.roomID,
            update: .sendError(transactionId: "tx1", error: .genericApiError(msg: "502"), isRecoverable: true))
        #expect(!service.retryingSendKeys.contains(key))
        #expect(service.displayedSendFailure(for: key) != nil)
    }

    @Test("Offline cancel prompt does not falsely warn that the message may already have been delivered")
    func cancelPromptCopy() {
        let offline = SendCancelPrompt.copy(failed: false, offline: true)
        #expect(!offline.message.contains("already have been delivered"))
        #expect(offline.message.contains("offline"))

        let online = SendCancelPrompt.copy(failed: false, offline: false)
        #expect(online.message.contains("already have been delivered"))

        let failed = SendCancelPrompt.copy(failed: true, offline: true)
        #expect(failed.title == "Delete message?" && failed.action == "Delete")
    }

    @Test("Wait status distinguishes sending, reconnecting, head-of-line blocking, edits, and deletions")
    func sendWaitStatusResolution() {
        #expect(
            SendWaitStatus.resolve(
                pendingSend: true, sendFailure: nil, pendingChange: nil,
                waitingToReconnect: false, blockedByEarlierFailure: false) == .sending)
        #expect(
            SendWaitStatus.resolve(
                pendingSend: true, sendFailure: nil, pendingChange: nil,
                waitingToReconnect: true, blockedByEarlierFailure: false) == .waitingToReconnect)
        let blocked = SendWaitStatus.resolve(
            pendingSend: true, sendFailure: nil, pendingChange: nil,
            waitingToReconnect: false, blockedByEarlierFailure: true)
        #expect(blocked == .blockedByEarlierFailure && blocked?.showsImmediately == true)
        #expect(blocked?.label == "Waiting on an earlier message")
        #expect(
            SendWaitStatus.resolve(
                pendingSend: false, sendFailure: nil, pendingChange: .editing,
                waitingToReconnect: false, blockedByEarlierFailure: false) == .savingEdit)
        #expect(
            SendWaitStatus.resolve(
                pendingSend: false, sendFailure: nil, pendingChange: .deleting,
                waitingToReconnect: false, blockedByEarlierFailure: false) == .deleting)
    }

    @Test("Expired sessions refuse sends and uploads, preserve soft-logout state, and warn before clearing unsent data")
    func expiredSessionRefusesSendsAndWarns() async throws {
        let f = ActionFixture()
        let service = f.service
        service.expireSessionForChecks(isSoftLogout: true)
        #expect(service.sessionExpired && service.sessionExpiredIsSoftLogout)

        await #expect(throws: MatrixServiceError.self) {
            try await service.sendMessage("Keep my draft safe", roomID: f.roomID)
        }
        #expect(f.main.writes.all.isEmpty)

        let dir = try TemporaryDirectory()
        let file = dir.url.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: file)
        do {
            try await service.uploadFile(file, roomID: f.roomID)
            Issue.record("Expected expired session to refuse file upload")
        } catch let error as MatrixServiceError {
            #expect(error.localizedDescription.contains("expired"))
        } catch {
            Issue.record("Expected MatrixServiceError, got \(error)")
        }

        #expect(SignOutWarning.forExpiredSession(queuedCount: 0, hasFailedSends: false, isSoftLogout: false) == nil)
        let softOnly = try #require(
            SignOutWarning.forExpiredSession(queuedCount: 0, hasFailedSends: false, isSoftLogout: true))
        #expect(softOnly.message.contains("recovery key"))
        let unsent = try #require(
            SignOutWarning.forExpiredSession(queuedCount: 2, hasFailedSends: false, isSoftLogout: false))
        #expect(unsent.message.contains("2 unsent messages"))
        let both = try #require(
            SignOutWarning.forExpiredSession(queuedCount: 1, hasFailedSends: true, isSoftLogout: true))
        #expect(both.message.contains("unsent") && both.message.contains("recovery key"))
    }

    @Test("Persisted unrecoverable send failures survive relaunch replay and never promise auto-send offline")
    func persistedSendFailureSurvivesRelaunch() throws {
        let folder = try TemporaryDirectory()
        let roots = [folder.path("support"), folder.path("caches")]
        let creds = SecureSessionStore(file: folder.path("credentials.json"))

        let first = MatrixService(credentials: creds, storeRoots: roots)
        first.user = ChatUser(id: "@me:example.org", name: "Me")
        first.applyConnection(
            MatrixConnectionFeedback(state: .running, isRetrying: false, canRetry: false, errorMessage: nil))
        first.handleSendQueueUpdate(
            roomID: "!bg:example.org",
            update: .sendError(transactionId: "t1", error: .invalidMimeType(mimeType: "x"), isRecoverable: false))
        #expect(first.failedSendRoomIDs == ["!bg:example.org"] && first.queuedSendCount == 0)

        // A .newLocalEvent replay for an already-known permanent failure must not clear the failure or mark pending.
        first.handleSendQueueUpdate(roomID: "!bg:example.org", update: .newLocalEvent(transactionId: "t1"))
        #expect(first.failedSendRoomIDs == ["!bg:example.org"] && first.queuedSendCount == 0)

        // Relaunch with the same store root: SDK replays persisted local echoes as .newLocalEvent.
        let relaunched = MatrixService(credentials: creds, storeRoots: roots)
        relaunched.user = ChatUser(id: "@me:example.org", name: "Me")
        relaunched.loadPersistedSendFailures(accountID: "@me:example.org")
        relaunched.beginInitialSendQueueReplay()
        relaunched.handleSendQueueUpdate(roomID: "!bg:example.org", update: .newLocalEvent(transactionId: "t1"))
        relaunched.finishInitialSendQueueReplay()
        #expect(relaunched.failedSendRoomIDs == ["!bg:example.org"] && relaunched.queuedSendCount == 0)

        // If the persisted transaction is no longer present on a later launch, reconciliation prunes the stale record.
        let cleaned = MatrixService(credentials: creds, storeRoots: roots)
        cleaned.user = ChatUser(id: "@me:example.org", name: "Me")
        cleaned.loadPersistedSendFailures(accountID: "@me:example.org")
        cleaned.beginInitialSendQueueReplay()
        cleaned.finishInitialSendQueueReplay()
        #expect(cleaned.failedSendRoomIDs.isEmpty && cleaned.queuedSendCount == 0)
    }

    @Test("Cancelling a queued follower behind a failed message does not re-enable the paused room queue")
    func cancellingFollowerDoesNotResumeRoomQueue() async throws {
        let f = ActionFixture()
        let service = f.service
        f.room.enableSendQueue(enable: false)
        service.applyConnection(
            MatrixConnectionFeedback(state: .running, isRetrying: false, canRetry: false, errorMessage: nil))
        func localEvent(_ tx: String, state: EventSendState) -> EventTimelineItem {
            EventTimelineItem(
                isRemote: false, eventOrTransactionId: .transactionId(transactionId: tx),
                sender: f.userID, senderProfile: .unavailable, forwarder: nil, forwarderProfile: nil,
                isOwn: true, isEditable: true,
                content: .msgLike(
                    content: MsgLikeContent(
                        kind: .message(
                            content: MessageContent(
                                msgType: .text(content: TextMessageContent(body: tx, formatted: nil)), body: tx,
                                isEdited: false, mentions: nil)),
                        inReplyTo: nil, threadRoot: nil, threadSummary: nil)),
                reactions: [], eventTypeRaw: "m.room.message", timestamp: 1_000,
                localSendState: state, editSendState: nil, redactionSendState: nil, localCreatedAt: nil,
                readReceipts: [:], origin: nil, canBeRepliedTo: true,
                lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
        }
        let failed = localEvent("tx1", state: .sendingFailed(error: .genericApiError(msg: "502"), isRecoverable: true))
        let follower = localEvent("tx2", state: .notSentYet(progress: nil))
        service.projectMediaCaptionForChecks(
            [FakeTimelineItem(failed), FakeTimelineItem(follower)], roomID: f.roomID, inThread: false)
        let followerMessage = try #require(service.messages.first { $0.eventID == "tx2" })
        #expect(try await service.cancelMessage(followerMessage))
        #expect(!f.room.isSendQueueEnabled())

        let failedMessage = try #require(service.messages.first { $0.eventID == "tx1" })
        #expect(try await service.cancelMessage(failedMessage))
        #expect(f.room.isSendQueueEnabled())
    }
}
