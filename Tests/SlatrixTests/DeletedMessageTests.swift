import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// How a room's event cache or server answers for one event.
enum EventAnswer: CaseIterable, Sendable {
    case message
    case deleted
    case failure
}

/// A stored event: the bindings throw on a deleted message's content, as they do for the SDK's redacted form.
private final class StoredEvent: TimelineEvent, @unchecked Sendable {
    let deleted: Bool
    init(deleted: Bool) {
        self.deleted = deleted
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func content() throws -> TimelineEventContent {
        if deleted { throw ClientError.Generic(msg: "Failed to get original content", details: nil) }
        return .messageLike(
            content: .roomMessage(
                messageType: .text(content: TextMessageContent(body: "Hello", formatted: nil)), inReplyToEventId: nil))
    }
}

/// A room whose event cache or server answers each event as `answers` says; a gate holds every answer.
final class AnsweringRoom: Room, @unchecked Sendable {
    private let identifier: String
    private let lock = NSLock()
    private var values: [String: EventAnswer]
    let asked = Recorder<String>()
    let gate = Gate()
    init(_ id: String, answers: [String: EventAnswer]) {
        identifier = id
        values = answers
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
        await gate.wait()
        switch answers[eventId] ?? .failure {
        case .message: return StoredEvent(deleted: false)
        case .deleted: return StoredEvent(deleted: true)
        case .failure: throw URLError(.notConnectedToInternet)
        }
    }
}

@MainActor
struct DeletedMessageTests {
    let service = MatrixService()

    private func use(_ rooms: [Room]) {
        service.configureRoomOpenForChecks(
            client: FakeClient(rooms: rooms), roomList: FakeRoomListService(),
            user: ChatUser(id: "@me:example.org", name: "Me"))
    }

    // capability: message.deleted
    @Test(
        "A message is gone only when the event cache or the server holds it deleted; a failed answer keeps it",
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

    // capability: message.deleted
    @Test("Activity drops the rows of deleted messages it hasn't opened; any other answer keeps its row")
    func activityDropsDeleted() async {
        let ids = ["$deleted", "$message", "$offline", "$opened"]
        let room = AnsweringRoom(
            Self.room, answers: ["$deleted": .deleted, "$message": .message, "$offline": .failure, "$opened": .deleted])
        use([room])
        for (age, id) in ids.enumerated() { service.activity.record(item(id, age: age)) }
        service.activity.markSeen { $0.eventID == "$opened" }
        await service.recheckActivity()
        #expect(service.activity.items.compactMap(\.eventID) == ["$message", "$offline", "$opened"])
    }

    // capability: message.deleted
    @Test("A pass asks about the newest rows first, each once, and no more than its bound")
    func boundedPass() async {
        let ids = (0..<(MatrixService.recheckLimit + 3)).map { "$m\($0)" }
        let room = AnsweringRoom(Self.room, answers: Dictionary(uniqueKeysWithValues: ids.map { ($0, .deleted) }))
        use([room])
        for (age, id) in ids.enumerated() { service.activity.record(item(id, age: age)) }
        await service.recheckActivity()
        #expect(room.asked.all == Array(ids.prefix(MatrixService.recheckLimit)))
        #expect(service.activity.items.compactMap(\.eventID) == Array(ids.suffix(3)))
    }

    // capability: message.deleted
    @Test("Two passes at once never ask about one message twice")
    func overlappingPasses() async {
        let ids = ["$first", "$second"]
        let room = AnsweringRoom(Self.room, answers: ["$first": .deleted, "$second": .deleted])
        use([room])
        for (age, id) in ids.enumerated() { service.activity.record(item(id, age: age)) }
        room.gate.arm()
        let first = Task { await service.recheckActivity() }
        #expect(await eventually { room.asked.all == ["$first"] })
        let second = Task { await service.recheckActivity() }
        #expect(await eventually { room.asked.all == ["$first", "$second"] })
        room.gate.release()
        await first.value
        await second.value
        #expect(room.asked.all.sorted() == ids.sorted() && service.activity.items.isEmpty)
    }

    enum Interruption: CaseIterable {
        /// Activity closed, which cancels its pass.
        case closed
        case accountChanged
        /// The row went some other way while the question was out.
        case rowGone
    }

    // capability: message.deleted
    @Test(
        "An answer that lands after Activity closed, the account changed or its row went changes nothing",
        arguments: Interruption.allCases)
    func lateAnswer(_ interruption: Interruption) async {
        let room = AnsweringRoom(Self.room, answers: ["$deleted": .deleted])
        use([room])
        let withdrawn = Recorder<String>()
        service.onMessageGone = { withdrawn.append($1) }
        service.activity.record(item("$deleted"))
        room.gate.arm()
        let pass = Task { await service.recheckActivity() }
        #expect(await eventually { room.gate.isWaiting })
        switch interruption {
        case .closed: pass.cancel()
        case .accountChanged:
            service.configureMessageActionsForChecks(
                client: FakeClient(rooms: [room]), main: nil, thread: nil, rootID: nil, sessionID: UUID(),
                selectionID: UUID(), threadID: UUID())
        case .rowGone: service.activity.clear()
        }
        room.gate.release()
        await pass.value
        #expect(withdrawn.all.isEmpty)
        #expect(service.activity.items.isEmpty == (interruption == .rowGone))
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
