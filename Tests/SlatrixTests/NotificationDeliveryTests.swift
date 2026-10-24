import Foundation
import Testing

@testable import Slatrix

private enum TransportFailure: Error { case authorization, submission }
private struct MissingContinuation: Error {}

/// The OS notification center: the test answers each permission check and submission.
@MainActor private final class Transport: DesktopNotificationTransport {
    private(set) var authorizationCalls = 0
    private(set) var pendingAuthorizations: [Int: CheckedContinuation<Bool, Error>] = [:]
    private(set) var attempts: [DesktopNotificationRequest] = []
    private(set) var pendingAdds: [String: CheckedContinuation<Void, Error>] = [:]
    private(set) var delivered: [String: DesktopNotificationRequest] = [:]
    private(set) var removed: [String] = []

    func isAuthorized() async throws -> Bool {
        let index = authorizationCalls
        authorizationCalls += 1
        return try await withCheckedThrowingContinuation { pendingAuthorizations[index] = $0 }
    }
    func add(_ request: DesktopNotificationRequest) async throws {
        attempts.append(request)
        try await withCheckedThrowingContinuation { pendingAdds[request.identifier] = $0 }
        // The OS shows a submission only after add() returns, possibly after clear() already ran.
        delivered[request.identifier] = request
    }
    func remove(_ identifier: String) {
        removed.append(identifier)
        delivered[identifier] = nil
    }
    func clear() { delivered = [:] }

    func authorize(_ index: Int, _ result: Result<Bool, Error>) throws {
        guard let continuation = pendingAuthorizations.removeValue(forKey: index) else { throw MissingContinuation() }
        continuation.resume(with: result)
    }
    func finishAdd(_ identifier: String, _ result: Result<Void, Error> = .success(())) throws {
        guard let continuation = pendingAdds.removeValue(forKey: identifier) else { throw MissingContinuation() }
        continuation.resume(with: result)
    }
}

private let accountA = "@alice:example.org"
private let accountB = "@bob:example.org"

private func message(account: String = accountA, eventID: String? = "$event", sound: Bool = true) throws
    -> DesktopMessageNotification
{
    let target = try #require(
        MatrixNotificationTarget(accountID: account, roomID: "!room:example.org", eventID: eventID))
    return DesktopMessageNotification(target: target, title: "Conversation", body: "Notification", playSound: sound)
}

private func invalidPayload(_ index: Int) -> [AnyHashable: Any] {
    let room = "!room:example.org"
    return [
        ["roomID": "!legacy:example.org"],
        ["slatrixVersion": "2", "accountID": accountA, "roomID": room],
        ["slatrixVersion": 1, "accountID": accountA, "roomID": room],
        ["slatrixVersion": "1", "accountID": 42, "roomID": room],
        ["slatrixVersion": "1", "accountID": accountA, "roomID": [room]],
        ["slatrixVersion": "1", "accountID": accountA, "roomID": room, "eventID": 42],
        ["slatrixVersion": "1", "accountID": accountA, "roomID": room, "eventID": NSNull()],
        ["slatrixVersion": "1", "accountID": "alice:example.org", "roomID": room],
        ["slatrixVersion": "1", "accountID": "@alice", "roomID": room],
        ["slatrixVersion": "1", "accountID": accountA, "roomID": "#alias:example.org"],
        ["slatrixVersion": "1", "accountID": accountA, "roomID": room, "eventID": "event"],
        ["slatrixVersion": "1", "accountID": "@alice:\nexample.org", "roomID": room],
        ["slatrixVersion": "1", "accountID": accountA, "roomID": "!room:\u{0000}example.org"],
        ["slatrixVersion": "1", "accountID": accountA, "roomID": room, "eventID": "$event\t"],
        ["slatrixVersion": "1", "accountID": "@a:" + String(repeating: "a", count: 2_046), "roomID": room],
        ["slatrixVersion": "1", "accountID": accountA, "roomID": "!" + String(repeating: "r", count: 2_048)],
        [
            "slatrixVersion": "1", "accountID": accountA, "roomID": room,
            "eventID": "$" + String(repeating: "é", count: 1_024),
        ],
    ][index]
}

@MainActor
struct NotificationPayloadTests {
    @Test("Without previews, a notification hides sender, conversation and text but keeps its route and sound")
    func hiddenPreview() throws {
        let original = try message()
        let hidden = original.applyingPreviewPreference(false)
        #expect(hidden.title == "Slatrix" && hidden.body == "You have a new message")
        #expect(hidden.target == original.target && hidden.playSound == original.playSound)
        let shown = original.applyingPreviewPreference(true)
        #expect(shown.title == original.title && shown.body == original.body)
    }

    @Test("A notification's route survives the round trip through the OS payload; an invite carries no event")
    func targetRoundTrip() throws {
        let event = try message().target
        let invite = try message(eventID: nil).target
        #expect(MatrixNotificationTarget(userInfo: event.userInfo) == event)
        #expect(MatrixNotificationTarget(userInfo: invite.userInfo) == invite && invite.userInfo["eventID"] == nil)
    }

    @Test(
        "A payload with a wrong version, wrong types, malformed or oversized IDs, or control characters is refused",
        arguments: 0..<17)
    func rejectsInvalidPayload(index: Int) {
        #expect(MatrixNotificationTarget(userInfo: invalidPayload(index)) == nil)
    }

    @Test("IDs right at the byte limit are accepted")
    func acceptsLimit() {
        #expect(
            MatrixNotificationTarget(
                accountID: accountA, roomID: "!" + String(repeating: "r", count: 2_047),
                eventID: "$" + String(repeating: "e", count: 2_047)) != nil)
    }
}

/// The fake OS waits for the test to answer, so a regression that submits unexpectedly hangs instead of failing.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NotificationDeliveryTests {
    private let transport = Transport()
    private let delivery: DesktopNotificationDelivery

    init() {
        delivery = DesktopNotificationDelivery(transport: transport)
        delivery.useAccount(accountA)
    }

    private func deliver(_ message: DesktopMessageNotification) -> Task<Bool, Error> {
        Task { try await delivery.deliver(message) }
    }
    private func awaitAuthorization(_ index: Int = 0) async {
        #expect(await eventually { transport.pendingAuthorizations[index] != nil })
    }
    private func awaitSubmission(_ count: Int = 1) async {
        #expect(await eventually { transport.attempts.count == count })
    }

    @Test("A permitted notification is shown with its exact route, text and sound, even if the account is re-selected")
    func delivers() async throws {
        let original = try message()
        let task = deliver(original)
        await awaitAuthorization()
        delivery.useAccount(accountA)
        try transport.authorize(0, .success(true))
        await awaitSubmission()
        let request = transport.attempts[0]
        #expect(request.message.target == original.target && request.message.playSound)
        #expect(request.message.title == original.title && request.message.body == original.body)
        try transport.finishAdd(request.identifier)
        #expect(try await task.value)
        #expect(transport.delivered[request.identifier] != nil)
    }

    @Test("An invitation is shown silently without an event, next to message notifications")
    func deliversInvitation() async throws {
        let first = deliver(try message())
        await awaitAuthorization()
        try transport.authorize(0, .success(true))
        await awaitSubmission()
        try transport.finishAdd(transport.attempts[0].identifier)
        _ = try await first.value
        let invitation = deliver(try message(eventID: nil, sound: false))
        await awaitAuthorization(1)
        try transport.authorize(1, .success(true))
        await awaitSubmission(2)
        let request = transport.attempts[1]
        #expect(request.message.target.eventID == nil && !request.message.playSound)
        try transport.finishAdd(request.identifier)
        #expect(try await invitation.value)
        #expect(transport.delivered.count == 2)
    }

    @Test("A notification for another account is dropped before asking for permission")
    func wrongAccount() async throws {
        delivery.useAccount(accountB)
        #expect(try await !delivery.deliver(message()))
        #expect(transport.authorizationCalls == 0 && transport.attempts.isEmpty)
    }

    @Test(
        "Clearing, or switching accounts and back, drops a notification still waiting for permission",
        arguments: [true, false])
    func invalidatedWhileAuthorizing(clearOnly: Bool) async throws {
        let task = deliver(try message())
        await awaitAuthorization()
        if clearOnly {
            delivery.clear()
        } else {
            delivery.useAccount(accountB)
            delivery.useAccount(accountA)
        }
        try transport.authorize(0, .success(true))
        #expect(try await !task.value)
        #expect(transport.attempts.isEmpty)
    }

    @Test("Denied permission is reported for the current account and never submits")
    func deniedCurrent() async throws {
        let task = deliver(try message())
        await awaitAuthorization()
        try transport.authorize(0, .success(false))
        await #expect(throws: DesktopNotificationError.notificationsDisabled) { _ = try await task.value }
        #expect(transport.attempts.isEmpty)
    }

    @Test("A permission check that fails is reported for the current account and never submits")
    func authorizationErrorCurrent() async throws {
        let task = deliver(try message())
        await awaitAuthorization()
        try transport.authorize(0, .failure(TransportFailure.authorization))
        await #expect(throws: TransportFailure.authorization) { _ = try await task.value }
        #expect(transport.attempts.isEmpty)
    }

    @Test(
        "A permission denial or failure that arrives after the account changed is silent",
        arguments: [Result<Bool, Error>.success(false), .failure(TransportFailure.authorization)])
    func staleAuthorizationSilent(answer: Result<Bool, Error>) async throws {
        let task = deliver(try message())
        await awaitAuthorization()
        delivery.useAccount(nil)
        try transport.authorize(0, answer)
        #expect(try await !task.value)
        #expect(transport.attempts.isEmpty)
    }

    @Test("A notification the OS accepts after sign-out or clear is removed again", arguments: [true, false])
    func lateSubmissionRemoved(logout: Bool) async throws {
        let task = deliver(try message())
        await awaitAuthorization()
        try transport.authorize(0, .success(true))
        await awaitSubmission()
        let identifier = transport.attempts[0].identifier
        if logout { delivery.useAccount(nil) } else { delivery.clear() }
        try transport.finishAdd(identifier)
        #expect(try await !task.value)
        #expect(transport.delivered.isEmpty && transport.removed == [identifier])
    }

    @Test(
        "An OS submission failure is reported for the current account and silent after a switch",
        arguments: [false, true])
    func submissionFailure(stale: Bool) async throws {
        let task = deliver(try message())
        await awaitAuthorization()
        try transport.authorize(0, .success(true))
        await awaitSubmission()
        if stale { delivery.useAccount(accountB) }
        try transport.finishAdd(transport.attempts[0].identifier, .failure(TransportFailure.submission))
        if stale {
            #expect(try await !task.value)
        } else {
            await #expect(throws: TransportFailure.submission) { _ = try await task.value }
        }
        #expect(transport.delivered.isEmpty)
    }

    @Test("The old account's late requests neither submit again nor remove the new account's notification")
    func concurrentAccounts() async throws {
        let original = try message()
        let oldSubmission = deliver(original)
        await awaitAuthorization(0)
        try transport.authorize(0, .success(true))
        await awaitSubmission(1)
        let oldIdentifier = transport.attempts[0].identifier
        let oldAuthorization = deliver(original)
        await awaitAuthorization(1)
        delivery.useAccount(accountB)
        let currentMessage = try message(account: accountB, eventID: "$new-event", sound: false)
        let current = deliver(currentMessage)
        await awaitAuthorization(2)
        try transport.authorize(2, .success(true))
        await awaitSubmission(2)
        let currentIdentifier = transport.attempts[1].identifier
        try transport.finishAdd(currentIdentifier)
        #expect(try await current.value)
        try transport.authorize(1, .success(true))
        #expect(try await !oldAuthorization.value)
        try transport.finishAdd(oldIdentifier)
        #expect(try await !oldSubmission.value)
        #expect(transport.attempts.count == 2)
        #expect(Set(transport.delivered.keys) == [currentIdentifier] && transport.removed == [oldIdentifier])
        #expect(transport.delivered[currentIdentifier]?.message.target == currentMessage.target)
    }

    @Test(
        "A cancelled delivery never shows, whether cancelled during permission or submission", arguments: [false, true])
    func cancelled(duringAdd: Bool) async throws {
        let task = deliver(try message())
        await awaitAuthorization()
        if duringAdd {
            try transport.authorize(0, .success(true))
            await awaitSubmission()
            task.cancel()
            try transport.finishAdd(transport.attempts[0].identifier)
        } else {
            task.cancel()
            try transport.authorize(0, .success(true))
        }
        #expect(try await !task.value)
        #expect(transport.delivered.isEmpty)
    }
}
