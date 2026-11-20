import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// How a room's event cache or server answers for one event.
enum EventAnswer: CaseIterable, Sendable {
    case message
    case deleted
    /// Content the bindings can't read, such as an unsupported event type.
    case unreadable
    case failure
}

/// A stored event whose content the bindings fail to read with `failure`, as they do for the SDK's redacted form.
private final class StoredEvent: TimelineEvent, @unchecked Sendable {
    let failure: String?
    init(failure: String? = nil) {
        self.failure = failure
        super.init(noHandle: .init())
    }
    static func deleted() -> StoredEvent { StoredEvent(failure: "Failed to get original content") }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func eventId() -> String { "$event" }
    override func senderId() -> String { "@alice:example.org" }
    override func timestamp() -> UInt64 { 1_000 }
    override func threadRootEventId() -> String? { nil }
    override func content() throws -> TimelineEventContent {
        if let failure { throw ClientError.Generic(msg: failure, details: nil) }
        return .messageLike(
            content: .roomMessage(
                messageType: .text(content: TextMessageContent(body: "Hello", formatted: nil)), inReplyToEventId: nil))
    }
}

/// A room whose event cache or server answers each event as `answers` says; the gate holds the `held` ones.
final class AnsweringRoom: Room, @unchecked Sendable {
    private let identifier: String
    private let lock = NSLock()
    private var values: [String: EventAnswer]
    let asked = Recorder<String>()
    let gate = Gate()
    let held: Set<String>
    init(_ id: String, answers: [String: EventAnswer], held: Set<String> = []) {
        identifier = id
        values = answers
        self.held = held
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    var answers: [String: EventAnswer] {
        get { lock.withLock { values } }
        set { lock.withLock { values = newValue } }
    }
    override func id() -> String { identifier }
    override func loadOrFetchEvent(eventId: String) async throws -> TimelineEvent {
        asked.append(eventId)
        if held.contains(eventId) { await gate.wait() }
        switch answers[eventId] ?? .failure {
        case .message: return StoredEvent()
        case .deleted: return StoredEvent.deleted()
        case .unreadable: return StoredEvent(failure: "Unsupported Event Type: \"m.room.unknown\"")
        case .failure: throw URLError(.notConnectedToInternet)
        }
    }
}

@MainActor
struct DeletedMessageTests {
    let service = MatrixService.scratch()

    private func use(_ rooms: [Room]) {
        service.configureRoomOpenForChecks(
            client: FakeClient(rooms: rooms), roomList: FakeRoomListService(),
            user: ChatUser(id: "@me:example.org", name: "Me"))
    }

    // capability: message.deleted
    @Test(
        "A message is gone only when the event cache or the server holds it deleted; a failed or unreadable answer keeps it",
        arguments: EventAnswer.allCases)
    func messageExists(answer: EventAnswer) async {
        let room = AnsweringRoom("!room:example.org", answers: ["$event": answer])
        use([room])
        #expect(await service.messageExists(roomID: room.id(), eventID: "$event") == (answer != .deleted))
    }
}

/// Activity's rows for messages deleted since they came in, against SDK fakes.
extension DeletedMessageTests {
    private static let room = "!room:example.org"

    /// A message row, `age` seconds old, so a smaller age lists higher.
    private func item(_ eventID: String, age: Int = 0) -> ActivityItem {
        ActivityItem(
            id: ActivityService.key(roomID: Self.room, eventID: eventID), roomID: Self.room, eventID: eventID,
            roomName: "Room", senderID: "@alice:example.org", senderName: "Alice", body: "Text of \(eventID)",
            timestamp: Date(timeIntervalSince1970: 1_000_000 - Double(age)), hasMention: true, threadRootID: nil,
            kind: .message)
    }

    /// Notification Center as the window wires it to the service.
    private func notificationCenter() -> (FakeNotificationCenter, DesktopNotificationDelivery) {
        let center = FakeNotificationCenter()
        let delivery = DesktopNotificationDelivery(transport: center)
        delivery.useAccount("@me:example.org")
        service.notifications = delivery
        return (center, delivery)
    }

    private func show(_ eventID: String, in delivery: DesktopNotificationDelivery) async throws {
        let target = try #require(
            MatrixNotificationTarget(accountID: "@me:example.org", roomID: Self.room, eventID: eventID))
        #expect(
            try await delivery.deliver(
                DesktopMessageNotification(target: target, title: "Room", body: "New", playSound: true)))
    }

    // capability: message.deleted
    @Test("Activity drops the rows of deleted messages it hasn't opened; any other answer keeps its row")
    func activityDropsDeleted() async {
        let ids = ["$deleted", "$message", "$offline", "$opened"]
        let room = AnsweringRoom(
            Self.room, answers: ["$deleted": .deleted, "$message": .message, "$offline": .failure, "$opened": .deleted])
        use([room])
        for (age, id) in ids.enumerated() { service.activity.record(item(id, age: age)) }
        service.activity.markSeen { $0.eventID == "$opened" }
        await service.recheckCopies().value
        #expect(service.activity.items.compactMap(\.eventID) == ["$message", "$offline", "$opened"])
    }

    // capability: message.deleted
    @Test("With more rows than a pass asks about, the next pass asks about those not yet asked and reaches the oldest")
    func turns() async {
        let ids = (0...MatrixService.recheckLimit).map { "$m\($0)" }
        let oldest = ids[ids.count - 1]
        let room = AnsweringRoom(
            Self.room, answers: Dictionary(uniqueKeysWithValues: ids.map { ($0, $0 == oldest ? .deleted : .message) }))
        use([room])
        for (age, id) in ids.enumerated() { service.activity.record(item(id, age: age)) }
        await service.recheckCopies().value
        #expect(service.activity.items.compactMap(\.eventID) == ids)
        await service.recheckCopies().value
        #expect(service.activity.items.compactMap(\.eventID) == Array(ids.dropLast()))
    }

    // capability: message.deleted
    @Test("A banner that comes and goes between passes never keeps a deleted row from its turn")
    func changingList() async throws {
        let ids = (0..<(2 * MatrixService.recheckLimit - 1)).map { "$m\($0)" }
        let deleted = ids[MatrixService.recheckLimit - 1]
        var answers = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0 == deleted ? EventAnswer.deleted : .message) })
        answers["$banner"] = .message
        use([AnsweringRoom(Self.room, answers: answers)])
        for (age, id) in ids.enumerated() { service.activity.record(item(id, age: age)) }
        let (center, delivery) = notificationCenter()
        try await show("$banner", in: delivery)
        await service.recheckCopies().value
        // The reader closes it.
        center.remove(try #require(center.shown.first).identifier)
        await service.recheckCopies().value
        #expect(!service.activity.items.contains { $0.eventID == deleted })
    }

    // capability: message.deleted
    @Test(
        "A question still out holds only its message: a pass started meanwhile asks about the rest, and the answer applies"
    )
    func stuckQuestion() async {
        let room = AnsweringRoom(Self.room, answers: ["$stuck": .deleted, "$other": .deleted], held: ["$stuck"])
        use([room])
        service.activity.record(item("$stuck"))
        service.activity.record(item("$other", age: 1))
        room.gate.arm()
        let first = service.recheckCopies()
        #expect(await eventually { room.gate.isWaiting })
        let second = service.recheckCopies()
        #expect(await eventually { service.activity.items.compactMap(\.eventID) == ["$stuck"] })
        room.gate.release()
        await first.value
        await second.value
        #expect(service.activity.items.isEmpty)
    }

    // capability: message.deleted
    @Test("An answer that lands after the account changed changes nothing")
    func lateAnswer() async {
        let room = AnsweringRoom(Self.room, answers: ["$deleted": .deleted], held: ["$deleted"])
        use([room])
        service.activity.record(item("$deleted"))
        room.gate.arm()
        let pass = service.recheckCopies()
        #expect(await eventually { room.gate.isWaiting })
        service.configureMessageActionsForChecks(
            client: FakeClient(rooms: [room]), main: nil, thread: nil, rootID: nil, sessionID: UUID(),
            selectionID: UUID(), threadID: UUID())
        room.gate.release()
        await pass.value
        #expect(service.activity.items.compactMap(\.eventID) == ["$deleted"])
    }

    // capability: message.deleted
    @Test("A question still out from the account signed out never keeps the next one from asking about that message")
    func questionFromSignedOutAccount() async throws {
        let folder = try TemporaryDirectory()
        let matrix = MatrixService(
            credentials: SecureSessionStore(file: folder.path("credentials.json")),
            storeRoots: [folder.path("support"), folder.path("caches")])
        let before = AnsweringRoom(Self.room, answers: ["$shared": .deleted], held: ["$shared"])
        matrix.configureRoomOpenForChecks(
            client: FakeClient(rooms: [before]), roomList: FakeRoomListService(),
            user: ChatUser(id: "@me:example.org", name: "Me"))
        matrix.activity.record(item("$shared"))
        before.gate.arm()
        let held = matrix.recheckCopies()
        #expect(await eventually { before.gate.isWaiting })
        try await matrix.logoutLocally()
        matrix.configureRoomOpenForChecks(
            client: FakeClient(rooms: [AnsweringRoom(Self.room, answers: ["$shared": .deleted])]),
            roomList: FakeRoomListService(), user: ChatUser(id: "@other:example.org", name: "Other"))
        matrix.activity.record(item("$shared"))
        await matrix.recheckCopies().value
        #expect(matrix.activity.items.isEmpty)
        before.gate.release()
        await held.value
    }

    // capability: message.deleted
    @Test("A message whose content can't be read keeps its row and its banner")
    func unreadableStays() async throws {
        use([AnsweringRoom(Self.room, answers: ["$odd": .unreadable])])
        let (center, delivery) = notificationCenter()
        try await show("$odd", in: delivery)
        service.activity.record(item("$odd"))
        await service.recheckCopies().value
        await drainMainActor()
        #expect(service.activity.items.count == 1 && center.shown.count == 1)
    }

    // capability: message.deleted
    @Test("Taking back a deleted message's banner leaves another account's banner for the same message")
    func otherAccountsBanner() async throws {
        let (center, delivery) = notificationCenter()
        try await show("$gone", in: delivery)
        let elsewhere = try #require(
            MatrixNotificationTarget(accountID: "@other:example.org", roomID: Self.room, eventID: "$gone"))
        try await center.add(
            DesktopNotificationRequest(
                identifier: "elsewhere",
                message: DesktopMessageNotification(target: elsewhere, title: "Room", body: "New", playSound: true)))
        await delivery.withdraw([ActivityService.key(roomID: Self.room, eventID: "$gone")])
        #expect(center.shown.map(\.identifier) == ["elsewhere"])
    }

    // capability: message.deleted
    @Test("Notification Center is read only once a banner went up since the last clear")
    func readsAfterABanner() async throws {
        let (center, delivery) = notificationCenter()
        let key = ActivityService.key(roomID: Self.room, eventID: "$gone")
        await delivery.withdraw([key])
        #expect(center.reads == 0)
        try await show("$other", in: delivery)
        delivery.clear()
        await delivery.withdraw([key])
        #expect(center.reads == 0)
    }

    // capability: message.deleted
    @Test("A message deleted before its notification came makes no row, so no banner")
    func deletedBeforeNotification() {
        let notification = NotificationItem(
            event: .timeline(event: StoredEvent.deleted()), rawEvent: "",
            senderInfo: NotificationSenderInfo(displayName: "Alice", avatarUrl: nil, isNameAmbiguous: false),
            roomInfo: NotificationRoomInfo(
                displayName: "Room", avatarUrl: nil, canonicalAlias: nil, topic: nil, joinRule: nil,
                joinedMembersCount: 2, activeServiceMembersCount: 0, serviceMembers: [], isEncrypted: false,
                isDirect: false, isSpace: false, isDm: false), isNoisy: true, hasMention: true, threadId: nil,
            actions: nil)
        #expect(service.activity.receive(notification, roomID: Self.room, ownUserID: "@me:example.org") == nil)
        #expect(service.activity.items.isEmpty)
    }

    enum Place: CaseIterable {
        case open
        /// Open before another conversation took its place.
        case kept
        case thread
    }

    // capability: message.deleted
    @Test(
        "Messages deleted in an open or kept timeline leave Activity and Notification Center at once, in one read of it",
        arguments: Place.allCases)
    func deletedInTimeline(_ place: Place) async throws {
        let root = FakeTimelineItem(textEvent("$root", body: "Root"), uniqueID: "root")
        let message = FakeTimelineItem(textEvent("$gone", body: "Hello"), uniqueID: "gone")
        let also = FakeTimelineItem(textEvent("$also", body: "Hi"), uniqueID: "also")
        let room = FakeOpenRoom(Self.room, cached: [root, message, also])
        room.threadItems = [root, message, also]
        let other = FakeOpenRoom("!other:example.org", cached: [])
        use([room, other])
        let (center, delivery) = notificationCenter()
        for id in ["$gone", "$also", "$kept"] {
            try await show(id, in: delivery)
            service.activity.record(item(id))
        }
        await service.selectRoom(room.id())
        switch place {
        case .open: break
        case .kept: await service.selectRoom(other.id())
        case .thread:
            try await service.loadThread(try #require(service.messages.first))
            #expect(await eventually { service.threadMessages.count == 3 })
        }
        let timeline = try #require(place == .thread ? room.timelines.all.last : room.timelines.all.first)
        timeline.emit([
            .set(index: 1, value: FakeTimelineItem(textEvent("$gone", body: "", redacted: true), uniqueID: "gone")),
            .set(index: 2, value: FakeTimelineItem(textEvent("$also", body: "", redacted: true), uniqueID: "also")),
        ])
        await drainMainActor()
        #expect(service.activity.items.compactMap(\.eventID) == ["$kept"])
        #expect(await eventually { center.shown.map(\.target.eventID) == ["$kept"] })
        #expect(center.reads == 1)
    }
}

/// The real SDK against the loopback homeserver: what it answers once a message is deleted on the server.
extension DeletedMessageTests {
    // capability: message.deleted
    @Test(
        "A message deleted on the server is gone, asked of the server or read from the event cache",
        arguments: [false, true])
    func deletedOnServer(cached: Bool) async throws {
        let server = try await FakeHomeserver(
            room: "!room:localhost",
            messages: [
                [
                    "type": "m.room.message", "event_id": "$hello", "sender": "@alice:localhost",
                    "origin_server_ts": 1, "content": ["msgtype": "m.text", "body": "Hello"],
                ]
            ])
        let scratch = try TemporaryDirectory()
        let alice = try await signIn("alice", to: server, in: scratch)
        let reader = try await signIn("reader", to: server, in: scratch)
        let room = try await reader.joinRoomById(roomId: server.room)
        service.configureRoomOpenForChecks(
            client: reader, roomList: FakeRoomListService(), user: ChatUser(id: "@reader:localhost", name: "Reader"))
        #expect(await service.messageExists(roomID: server.room, eventID: "$hello"))
        try await alice.joinRoomById(roomId: server.room).redact(eventId: "$hello", reason: nil)
        if cached { _ = try await room.timeline().paginateBackwards(numEvents: 20) }
        let fetches = server.eventFetches
        #expect(await !service.messageExists(roomID: server.room, eventID: "$hello"))
        #expect(server.eventFetches == fetches + (cached ? 0 : 1))
    }
}
