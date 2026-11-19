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

    // capability: thread.send-to-channel
    @Test(
        "A reply goes to the channel only while its thread's box shows checked, which it never does with files attached",
        arguments: [
            ("$root", "$root", false, true), ("$root", "$root", true, false), (nil, "$root", false, false),
            ("$other", "$root", false, false), ("$root", nil, false, false),
        ] as [(String?, String?, Bool, Bool)])
    func copiesOnlyWhenShownChecked(checked: String?, thread: String?, files: Bool, copies: Bool) {
        #expect(ChannelCopy.isChecked(checkedRootID: checked, threadID: thread, hasFiles: files) == copies)
    }
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

    /// The copy's event content.
    private func copy() throws -> [String: JSON] {
        let content = try JSONDecoder().decode(JSON.self, from: Data(try #require(room.raw.all.first).content.utf8))
        guard case .object(let fields) = content else { return [:] }
        return fields
    }

    // capability: thread.send-to-channel
    @Test(
        "A reply also sent to the channel goes to its thread, then to the channel as a reply to it once it's sent",
        arguments: [false, true])
    func copiesOnceSent(sentBeforeTheSendReturns: Bool) async throws {
        let thread = FakeLiveTimeline([])
        configure(thread: thread)

        if sentBeforeTheSendReturns {
            thread.sendGate.arm()
            let sending = Task {
                try await service.sendMessage("On it", threadRootID: "$root", roomID: room.id(), alsoToChannel: true)
            }
            #expect(await eventually { thread.sendGate.isWaiting })
            room.queue(.sentEvent(transactionId: "txn-1", eventId: "$reply"))
            thread.sendGate.release()
            try await sending.value
        } else {
            try await service.sendMessage("On it", threadRootID: "$root", roomID: room.id(), alsoToChannel: true)
            room.queue(.sentEvent(transactionId: "txn-1", eventId: "$reply"))
        }

        #expect(await eventually { room.raw.all.count == 1 })
        #expect(room.raw.all.first?.type == "m.room.message")
        let fields = try copy()
        #expect(fields["body"] == .string("On it"))
        #expect(fields["m.relates_to"] == .object(["m.in_reply_to": .object(["event_id": .string("$reply")])]))
    }

    // capability: thread.send-to-channel
    @Test("A channel's copy quotes the reply its own send queued, not the same words sent just before it")
    func quotesItsOwnReply() async throws {
        let thread = FakeLiveTimeline([])
        configure(thread: thread)

        try await service.sendMessage("On it", threadRootID: "$root", roomID: room.id())
        try await service.sendMessage("On it", threadRootID: "$root", roomID: room.id(), alsoToChannel: true)
        room.queue(.sentEvent(transactionId: "txn-1", eventId: "$first"))
        room.queue(.sentEvent(transactionId: "txn-2", eventId: "$second"))

        #expect(await eventually { room.raw.all.count == 1 })
        #expect(try copy()["m.relates_to"] == .object(["m.in_reply_to": .object(["event_id": .string("$second")])]))
    }

    @Test("A reply whose send was cancelled, or returned after the session changed, copies nothing to the channel")
    func noCopy() async throws {
        let thread = FakeLiveTimeline([])
        configure(thread: thread)
        thread.sendGate.arm()
        let stale = Task {
            try await service.sendMessage("On it", threadRootID: "$root", roomID: room.id(), alsoToChannel: true)
        }
        #expect(await eventually { thread.sendGate.isWaiting })
        configure(thread: thread)
        thread.sendGate.release()
        try await stale.value
        room.queue(.sentEvent(transactionId: "txn-1", eventId: "$stale"))
        try await service.sendMessage("Never mind", threadRootID: "$root", roomID: room.id(), alsoToChannel: true)
        room.queue(.cancelledLocalEvent(transactionId: "txn-2"))

        // The new session's own copy goes out after the others would have.
        try await service.sendMessage("Later", threadRootID: "$root", roomID: room.id(), alsoToChannel: true)
        room.queue(.sentEvent(transactionId: "txn-3", eventId: "$fresh"))
        #expect(await eventually { room.raw.all.contains { $0.content.contains("$fresh") } })
        await drainMainActor()
        #expect(room.raw.all.count == 1)
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
