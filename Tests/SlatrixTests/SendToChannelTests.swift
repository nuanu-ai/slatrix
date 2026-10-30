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

private final class CopyRoom: Room, @unchecked Sendable {
    /// Raw events sent to the room, as their type and JSON content.
    let raw = Recorder<(type: String, content: String)>()
    override func membership() -> Membership { .joined }
    override func sendRaw(eventType: String, content: String) async throws -> String {
        raw.append((eventType, content))
        return "$copy"
    }
    /// Every event it holds is a reply in the thread of "$root".
    override func loadOrFetchEvent(eventId: String) async throws -> TimelineEvent {
        ThreadReplyEvent(noHandle: .init())
    }
    override func timelineWithConfiguration(configuration: TimelineConfiguration) async throws -> Timeline {
        throw ClientError.Generic(msg: "no timelines here", details: nil)
    }
}

private final class ThreadReplyEvent: TimelineEvent, @unchecked Sendable {
    override func threadRootEventId() -> String? { "$root" }
}

private final class CopyClient: Client, @unchecked Sendable {
    let room = CopyRoom(noHandle: .init())
    override func getRoom(roomId: String) throws -> Room? { room }
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
    // capability: thread.send-to-channel
    @Test("A reply also sent to the channel goes to its thread, then to the channel as a reply to it once it's sent")
    func copiesOnceSent() async throws {
        let service = MatrixService()
        let client = CopyClient(noHandle: .init())
        // An earlier reply still sending, which the copy must not mistake for this one.
        let thread = FakeLiveTimeline([own(.transactionId(transactionId: "earlier"), body: "First")])
        service.user = ChatUser(id: "@sender:example.org", name: "Sender")
        service.selectedRoomID = "!room:example.org"
        service.configureMessageActionsForChecks(
            client: client, main: nil, thread: thread, rootID: "$root", sessionID: UUID(), selectionID: UUID(),
            threadID: UUID())

        try await service.sendMessage("On it", threadRootID: "$root", roomID: "!room:example.org", alsoToChannel: true)
        thread.emit([.pushBack(value: own(.transactionId(transactionId: "this"), body: "On it"))])
        thread.emit([.set(index: 0, value: own(.eventId(eventId: "$earlier"), body: "First"))])
        thread.emit([.set(index: 1, value: own(.eventId(eventId: "$reply"), body: "On it"))])

        #expect(thread.sent.all.count == 1)
        #expect(await eventually { client.room.raw.all.count == 1 })
        let copy = try #require(client.room.raw.all.first)
        let content = try JSONDecoder().decode(JSON.self, from: Data(copy.content.utf8))
        guard case .object(let fields) = content, case .object(let relation) = fields["m.relates_to"] else {
            Issue.record("the copy isn't a reply: \(copy.content)")
            return
        }
        #expect(copy.type == "m.room.message" && fields["body"] == .string("On it"))
        #expect(relation["m.in_reply_to"] == .object(["event_id": .string("$reply")]))
    }

    @Test("A channel's copy names its thread by the thread's first message, as Slack's \"replied to a thread:\" does")
    func threadRoot() async {
        let service = MatrixService()
        service.configureMessageActionsForChecks(
            client: CopyClient(noHandle: .init()), main: nil, thread: nil, rootID: nil, sessionID: UUID(),
            selectionID: UUID(), threadID: UUID())
        service.messages = [
            ChatMessage(
                id: "$root", roomID: "!room:example.org", senderID: "@bob:example.org", senderName: "Bob",
                body: "Can we ship Friday?", timestamp: Date())
        ]
        let root = await service.threadRoot(roomID: "!room:example.org", replyID: "$reply")
        #expect(root?.body == "Can we ship Friday?")
    }
}
