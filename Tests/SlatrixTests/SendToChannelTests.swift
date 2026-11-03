import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// Any JSON value, compared by content, so an event's keys can come in any order.
indirect enum JSON: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let array = try? value.decode([JSON].self) {
            self = .array(array)
        } else {
            self = .object(try value.decode([String: JSON].self))
        }
    }
}

struct SendToChannelTests {
    struct Send: Decodable, CustomTestStringConvertible {
        var name: String
        var draft: String
        var replyTo: String
        var content: JSON
        var testDescription: String { name }
    }

    struct Spec: Decodable { var send: [Send] }

    // capability: thread.send-to-channel
    @Test(
        "The channel's copy of a thread reply, from spec/send-to-channel.json",
        arguments: try SharedSpec.decode("spec/send-to-channel.json", as: Spec.self).send)
    func copy(spec: Send) throws {
        let content = try ChannelCopy.content(ComposerFormat.message(draft: spec.draft), replyTo: spec.replyTo)
        #expect(try JSONDecoder().decode(JSON.self, from: Data(content.utf8)) == spec.content)
    }
}

/// The reader's own text message in a timeline, still sending under a transaction ID or sent under an event ID.
private func own(_ id: EventOrTransactionId, body: String) -> FakeTimelineItem {
    var event = textEvent("$unused", body: body, sender: "@sender:example.org")
    event.eventOrTransactionId = id
    if case .transactionId = id { event.isRemote = false }
    event.isOwn = true
    // The SDK keeps an item's unique ID when its local echo turns remote.
    return FakeTimelineItem(event, uniqueID: body)
}

@MainActor
struct SendToChannelServiceTests {
    private let service = MatrixService()
    private let room = FakeOpenRoom("!room:example.org", cached: [])

    init() {
        service.user = ChatUser(id: "@sender:example.org", name: "Sender")
        service.selectedRoomID = room.id()
    }

    private func configure(thread: Timeline?) {
        service.configureMessageActionsForChecks(
            client: FakeClient(rooms: [room]), main: nil, thread: thread, rootID: thread == nil ? nil : "$root",
            sessionID: UUID(), selectionID: UUID(), threadID: UUID())
    }

    // capability: thread.send-to-channel
    @Test(
        "A reply also sent to the channel goes to its thread, then to the channel as a reply to it once it's sent",
        arguments: [false, true])
    func copiesOnceSent(sentAtOnce: Bool) async throws {
        let thread = FakeLiveTimeline([])
        configure(thread: thread)

        try await service.sendMessage("On it", threadRootID: "$root", roomID: room.id(), alsoToChannel: true)
        // An earlier reply's echo that lands only now must not be taken for this one.
        thread.emit([.pushBack(value: own(.transactionId(transactionId: "earlier"), body: "First"))])
        if sentAtOnce {
            thread.emit([
                .set(index: 0, value: own(.eventId(eventId: "$earlier"), body: "First")),
                .pushBack(value: own(.eventId(eventId: "$reply"), body: "On it")),
            ])
        } else {
            thread.emit([.pushBack(value: own(.transactionId(transactionId: "this"), body: "On it"))])
            thread.emit([.set(index: 0, value: own(.eventId(eventId: "$earlier"), body: "First"))])
            thread.emit([.set(index: 1, value: own(.eventId(eventId: "$reply"), body: "On it"))])
        }

        #expect(await eventually { room.raw.all.count == 1 })
        let copy = try #require(room.raw.all.first)
        #expect(copy.type == "m.room.message")
        let content = try JSONDecoder().decode(JSON.self, from: Data(copy.content.utf8))
        guard case .object(let fields) = content, case .object(let relation) = fields["m.relates_to"] else {
            Issue.record("the copy isn't a reply: \(copy.content)")
            return
        }
        #expect(fields["body"] == .string("On it"))
        #expect(relation["m.in_reply_to"] == .object(["event_id": .string("$reply")]))
    }

    @Test("A channel's copy names its thread by the thread's first message, as Slack's \"replied to a thread:\" does")
    func threadOrigin() async {
        configure(thread: nil)
        room.threadRoots = ["$reply": "$root"]
        service.messages = [
            ChatMessage(
                id: "$root", roomID: room.id(), senderID: "@bob:example.org", senderName: "Bob",
                body: "Can we ship Friday?", timestamp: Date())
        ]
        let origin = await service.threadOrigin(roomID: room.id(), replyID: "$reply")
        #expect(origin?.root.eventID == "$root")
        #expect(origin?.preview == "Can we ship Friday?")
    }
}
