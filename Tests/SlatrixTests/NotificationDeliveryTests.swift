import Foundation
import Observation
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
    /// Whether a submission waits for the test to finish it; when false it is recorded and returns at once.
    var holdsAdds = true

    func isAuthorized() async throws -> Bool {
        let index = authorizationCalls
        authorizationCalls += 1
        return try await withCheckedThrowingContinuation { pendingAuthorizations[index] = $0 }
    }
    func add(_ request: DesktopNotificationRequest) async throws {
        attempts.append(request)
        if holdsAdds { try await withCheckedThrowingContinuation { pendingAdds[request.identifier] = $0 } }
        // The OS shows a submission only after add() returns, possibly after clear() already ran.
        delivered[request.identifier] = request
    }
    func remove(_ identifier: String) {
        removed.append(identifier)
        delivered[identifier] = nil
    }
    func clear() { delivered = [:] }
    /// Shown in the order they were submitted.
    func deliveredNotifications() async -> [DeliveredNotification] {
        attempts.enumerated().compactMap { order, request in
            guard delivered[request.identifier] != nil else { return nil }
            return DeliveredNotification(
                identifier: request.identifier, target: request.message.target,
                date: Date(timeIntervalSince1970: Double(order)), threadRootID: request.message.threadRootID)
        }
    }
    /// The reader closes a banner in Notification Center.
    func dismiss(_ identifier: String) { delivered[identifier] = nil }

    func authorize(_ index: Int, _ result: Result<Bool, Error>) throws {
        guard let continuation = pendingAuthorizations.removeValue(forKey: index) else { throw MissingContinuation() }
        continuation.resume(with: result)
    }
    func finishAdd(_ identifier: String, _ result: Result<Void, Error> = .success(())) throws {
        guard let continuation = pendingAdds.removeValue(forKey: identifier) else { throw MissingContinuation() }
        continuation.resume(with: result)
    }
}

/// A pane's answer to whether its message is seen: false while it isn't shown, nil until it lays the message out.
@MainActor @Observable private final class Pane {
    var seen: Bool? = false
    /// Whether delivery has asked for the pane's answer.
    @ObservationIgnored private(set) var asked = false
    var answer: Bool? {
        asked = true
        return seen
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
    // capability: notifications.previews
    @Test("Without previews, a notification hides sender, conversation and text but keeps its route and sound")
    func hiddenPreview() throws {
        let original = try message()
        let hidden = original.applyingPreviewPreference(false)
        #expect(hidden.title == "Slatrix" && hidden.body == "You have a new message")
        #expect(hidden.target == original.target && hidden.playSound == original.playSound)
        let shown = original.applyingPreviewPreference(true)
        #expect(shown.title == original.title && shown.body == original.body)
    }

    // capability: notifications.open
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

    // capability: notifications.alert
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

    // capability: notifications.alert
    @Test("A message the reader sees while the OS answers whether alerts may show goes unannounced, quietly")
    func seenWhileAuthorizing() async throws {
        let seen = Recorder<Void>()
        let task = Task { try await delivery.deliver(try message(), stillAnnounce: { seen.all.isEmpty }) }
        await awaitAuthorization()
        seen.append(())
        try transport.authorize(0, .success(false))
        #expect(try await task.value == false)
        #expect(transport.attempts.isEmpty)
    }

    /// The gate as the window asks it: the pane's first answer, announced unless it says seen.
    private func deliver(_ message: DesktopMessageNotification, pane: Pane) -> Task<Bool, Error> {
        Task {
            try await delivery.deliver(message) {
                await waitObserving(for: { pane.answer }, deadline: .now + .seconds(60)) != true
            }
        }
    }

    // capability: notifications.alert
    @Test("A pane that shows while the OS answers gets its chance to show the message, and then nothing is announced")
    func paneShownWhileAuthorizing() async throws {
        transport.holdsAdds = false
        let pane = Pane()
        let task = deliver(try message(), pane: pane)
        await awaitAuthorization()
        pane.seen = nil
        try transport.authorize(0, .success(true))
        #expect(await eventually { pane.asked })
        pane.seen = true
        #expect(try await task.value == false)
        #expect(transport.attempts.isEmpty)
    }

    // capability: notifications.alert
    @Test("A message seen once the OS has answered stays unannounced though its pane goes away before delivery ends")
    func seenVerdictStands() async throws {
        transport.holdsAdds = false
        let pane = Pane()
        pane.seen = nil
        let task = deliver(try message(), pane: pane)
        await awaitAuthorization()
        try transport.authorize(0, .success(true))
        #expect(await eventually { pane.asked })
        pane.seen = true
        await drainMainActor()
        pane.seen = false
        #expect(try await task.value == false)
        #expect(transport.attempts.isEmpty)
    }

    // capability: notifications.alert
    @Test(
        "A failed permission check stays quiet for a message the reader has seen and is reported otherwise",
        arguments: [true, false])
    func failedCheckAfterVerdict(seen: Bool) async throws {
        let pane = Pane()
        pane.seen = seen
        let task = deliver(try message(), pane: pane)
        await awaitAuthorization()
        try transport.authorize(0, .failure(TransportFailure.authorization))
        if seen {
            #expect(try await task.value == false)
        } else {
            await #expect(throws: TransportFailure.authorization) { try await task.value }
        }
        #expect(transport.attempts.isEmpty)
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

    // capability: notifications.permission
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

/// What a message notification says, from the shared cases in `spec/notification-text.json`.
struct NotificationTextTests {
    struct Case: Decodable, CustomTestStringConvertible {
        var name: String
        var room: String
        var sender: String
        var direct: Bool
        var reply: Bool?
        var body: String
        var title: String
        var text: String
        var testDescription: String { name }
    }

    struct Spec: Decodable { var cases: [Case] }

    private static let spec = Result { try SharedSpec.decode("spec/notification-text.json", as: Spec.self) }

    /// A synced notification's body passes through Activity's preview first; a Later reminder's comes from its message.
    @Test("A notification and a Later reminder read as in every shared case", arguments: try spec.get().cases)
    func text(spec: Case) {
        let reply = spec.reply ?? false
        let synced = DesktopMessageNotification.message(
            room: spec.room, sender: spec.sender, direct: spec.direct,
            body: ActivityService.previewBody(spec.body, formatted: nil, reply: reply))
        let later = DesktopMessageNotification.message(
            room: spec.room, sender: spec.sender, direct: spec.direct, body: spec.body, reply: reply)
        #expect(synced.title == spec.title && synced.text == spec.text)
        #expect(later.title == spec.title && later.text == spec.text)
    }
}

/// Banners of messages deleted after they came in.
extension NotificationDeliveryTests {
    /// Shows a banner for `eventID` and returns its identifier.
    private func show(_ eventID: String) async throws -> String {
        let index = transport.authorizationCalls
        let task = deliver(try message(eventID: eventID))
        await awaitAuthorization(index)
        try transport.authorize(index, .success(true))
        #expect(try await task.value)
        return try #require(transport.attempts.last).identifier
    }

    private func key(_ eventID: String) throws -> String {
        DesktopNotificationDelivery.key(try message(eventID: eventID).target)
    }

    // capability: message.deleted
    @Test("A deleted message's banner leaves Notification Center, and the others stay")
    func withdrawsDelivered() async throws {
        transport.holdsAdds = false
        _ = try await show("$gone")
        let kept = try await show("$kept")
        await delivery.withdraw([try key("$gone")])
        #expect(Array(transport.delivered.keys) == [kept])
    }

    // capability: message.deleted
    @Test(
        "A banner on its way when its message is deleted never stays, whether the OS had it yet or not",
        arguments: [false, true])
    func withdrawnOnTheWay(submitted: Bool) async throws {
        transport.holdsAdds = submitted
        let task = deliver(try message(eventID: "$gone"))
        await awaitAuthorization()
        if submitted {
            try transport.authorize(0, .success(true))
            await awaitSubmission()
        }
        await delivery.withdraw([try key("$gone")])
        if submitted {
            try transport.finishAdd(transport.attempts[0].identifier)
        } else {
            try transport.authorize(0, .success(true))
        }
        #expect(try await !task.value)
        #expect(transport.delivered.isEmpty)
    }

    // capability: message.deleted
    @Test("Two banners of one message on their way: the older one landing leaves the newer one to show")
    func sameMessageTwice() async throws {
        let older = deliver(try message(eventID: "$twice"))
        await awaitAuthorization(0)
        try transport.authorize(0, .success(true))
        await awaitSubmission(1)
        let newer = deliver(try message(eventID: "$twice"))
        await awaitAuthorization(1)
        try transport.authorize(1, .success(true))
        await awaitSubmission(2)
        try transport.finishAdd(transport.attempts[0].identifier)
        #expect(try await older.value)
        try transport.finishAdd(transport.attempts[1].identifier)
        #expect(try await newer.value)
        #expect(transport.delivered[transport.attempts[1].identifier] != nil)
    }

    // capability: message.deleted
    @Test("Coming back to the app asks about the banners still shown, newest first, and takes back those deleted")
    func recheckDelivered() async throws {
        transport.holdsAdds = false
        let old = try await show("$old")
        transport.dismiss(try await show("$dismissed"))
        _ = try await show("$new")
        let room = AnsweringRoom("!room:example.org", answers: ["$old": .message, "$new": .deleted])
        let matrix = MatrixService.scratch()
        matrix.configureRoomOpenForChecks(
            client: FakeClient(rooms: [room]), roomList: FakeRoomListService(),
            user: ChatUser(id: accountA, name: "Alice"))
        matrix.notifications = delivery
        await matrix.recheckCopies().value
        #expect(room.asked.all == ["$new", "$old"])
        #expect(await eventually { Array(transport.delivered.keys) == [old] })
    }

    private func show(roomID: String, eventID: String, threadRootID: String? = nil) async throws -> String {
        let target = try #require(MatrixNotificationTarget(accountID: accountA, roomID: roomID, eventID: eventID))
        let index = transport.authorizationCalls
        let task = deliver(
            DesktopMessageNotification(
                target: target, title: "Conversation", body: "Notification", playSound: true, threadRootID: threadRootID
            ))
        await awaitAuthorization(index)
        try transport.authorize(index, .success(true))
        #expect(try await task.value)
        return try #require(transport.attempts.last).identifier
    }

    // capability: notifications.alert
    @Test("Withdrawing a room or thread clears only its matching delivered and in-flight banners")
    func withdrawsReadRoomsAndThreads() async throws {
        transport.holdsAdds = false
        let mainA = try await show(roomID: "!a:example.org", eventID: "$m1")
        let threadA = try await show(roomID: "!a:example.org", eventID: "$t1", threadRootID: "$root")
        let otherThreadA = try await show(roomID: "!a:example.org", eventID: "$t2", threadRootID: "$other")
        let roomB = try await show(roomID: "!b:example.org", eventID: "$b1")

        // Reading only the main timeline clears mainA but preserves unread thread banners and roomB.
        await delivery.withdrawRooms(["!a:example.org"], includeThreads: false)
        #expect(Set(transport.delivered.keys) == [threadA, otherThreadA, roomB])
        #expect(transport.delivered[mainA] == nil)

        // Reading thread $root clears only threadA.
        await delivery.withdrawThread(roomID: "!a:example.org", rootID: "$root")
        #expect(Set(transport.delivered.keys) == [otherThreadA, roomB])

        // Marking the whole room read clears remaining thread banners in !a, leaving !b untouched.
        await delivery.withdrawRooms(["!a:example.org"])
        #expect(Set(transport.delivered.keys) == [roomB])
    }

    // capability: notifications.alert
    @Test("Reading a room, reading a thread, marking a room read, or syncing a cross-device read withdraws banners")
    func serviceWithdrawsBannersWhenRead() async throws {
        let center = FakeNotificationCenter()
        let serviceDelivery = DesktopNotificationDelivery(transport: center)
        serviceDelivery.useAccount("@owner:example.org")

        func showBanner(roomID: String, eventID: String, threadRootID: String? = nil) async throws {
            let target = try #require(
                MatrixNotificationTarget(accountID: "@owner:example.org", roomID: roomID, eventID: eventID))
            #expect(
                try await serviceDelivery.deliver(
                    DesktopMessageNotification(
                        target: target, title: "Room", body: "Hello", playSound: false, threadRootID: threadRootID)))
        }

        let f = ActionFixture()
        f.service.notifications = serviceDelivery
        f.service.messages = [f.message(f.rootID)]
        f.service.threadMessages = [f.message(f.rootID), f.message("$reply", inThread: true)]
        f.service.configureThreadReadForChecks(
            client: f.client, main: f.main, thread: f.thread, rootID: f.rootID, sessionID: f.session,
            selectionID: f.selection, threadID: f.threadLoad, ready: true)

        try await showBanner(roomID: f.roomID, eventID: f.rootID)
        try await showBanner(roomID: f.roomID, eventID: "$reply", threadRootID: f.rootID)
        try await showBanner(roomID: "!other:example.org", eventID: "$other")

        // markVisibleRead withdraws the main-timeline banner while keeping the unread thread and other room banners.
        let mainTarget = ReadReceiptTarget(
            accountID: f.userID, sessionGeneration: f.session, timelineGeneration: f.selection, roomID: f.roomID,
            eventID: f.rootID)
        try await f.service.markVisibleRead(mainTarget, retries: []) { true }
        #expect(Set(center.shown.compactMap(\.target.eventID)) == ["$reply", "$other"])

        // markVisibleThreadRead withdraws the thread banner while keeping the other room's banner.
        let threadTarget = ThreadReadReceiptTarget(
            identity: try #require(f.service.threadReadIdentity), eventID: "$reply")
        try await f.service.markVisibleThreadRead(threadTarget, retries: []) { true }
        #expect(center.shown.compactMap(\.target.eventID) == ["$other"])

        // Cross-device sync transitioning !other from unread to read withdraws !other's banner.
        f.service.rooms = [
            ChatRoom(id: f.roomID, name: "Actions"),
            ChatRoom(id: "!other:example.org", name: "Other", unread: 1),
        ]
        f.service.rooms = [
            ChatRoom(id: f.roomID, name: "Actions"),
            ChatRoom(id: "!other:example.org", name: "Other", unread: 0),
        ]
        #expect(await eventually { center.shown.isEmpty })

        // Explicit Mark as read (setMarkedUnread(..., value: false)) withdraws both main and thread banners for a room.
        let openRoom = FakeOpenRoom("!marked:example.org", cached: [])
        let markService = MatrixService.scratch()
        markService.configureRoomOpenForChecks(
            client: FakeClient(rooms: [openRoom]), roomList: FakeRoomListService(),
            user: ChatUser(id: "@owner:example.org", name: "Owner"))
        markService.notifications = serviceDelivery
        try await showBanner(roomID: "!marked:example.org", eventID: "$m1")
        try await showBanner(roomID: "!marked:example.org", eventID: "$t1", threadRootID: "$r1")
        try await showBanner(roomID: "!keep:example.org", eventID: "$k1")
        try await markService.setMarkedUnread("!marked:example.org", value: false)
        #expect(center.shown.compactMap(\.target.eventID) == ["$k1"])
    }
}
