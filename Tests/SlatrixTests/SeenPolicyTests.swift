import Foundation
import Testing

@testable import Slatrix

struct SeenPolicyTests {
    struct Message: Decodable {
        let id, sender: String
        let readBy: [String]
    }
    struct Case: Decodable, CustomTestStringConvertible {
        let name, me: String
        let messages: [Message]
        let seen: [String: [String]]
        var testDescription: String { name }
    }
    struct Spec: Decodable { let cases: [Case] }

    // capability: message.seen
    @Test("Shared case", arguments: try SharedSpec.decode("spec/seen.json", as: Spec.self).cases)
    func sharedCase(_ row: Case) {
        #expect(SeenPolicy.readers(row.messages.map { ($0.id, $0.sender, $0.readBy) }, me: row.me) == row.seen)
    }
}

struct SeenHeaderTests {
    private func message(
        _ id: String, _ sender: String, at minute: Double, state: String = "sent", readBy: [String] = []
    )
        -> ChatMessage
    {
        var message = ChatMessage(
            id: id, roomID: "!r", senderID: sender, senderName: sender, body: id,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + minute * 60))
        message.sendState = state
        message.readBy = readBy
        return message
    }

    @Test("A group shows whether its newest sent message was read; groups still sending and others' groups show none")
    func groupHeaders() {
        let rows = TimelineLayout.rows(
            [
                message("a", "@me", at: 0), message("b", "@me", at: 1, readBy: ["@anna"]),
                message("c", "@me", at: 2, state: "sending"),
                message("d", "@anna", at: 3, readBy: ["@anna"]),
                message("e", "@me", at: 4),
                message("f", "@me", at: 5, state: "sending"),
                message("g", "@anna", at: 6), message("h", "@me", at: 7, state: "sending"),
            ], unreadBoundaryEventID: nil, groups: true, now: .now, calendar: .current, locale: .current)
        #expect(SeenPolicy.headers(rows, me: "@me") == ["a": ["@anna"], "e": []])
    }

    @Test("Who has seen it, by name, the first two and how many more")
    func tooltip() {
        let names = ["@a:x": "Alice", "@b:x": "Bob", "@c:x": "Carol", "@d:x": "Dan"]
        #expect(SeenPolicy.tooltip(["@a:x"]) { names[$0] } == "Seen by Alice")
        #expect(SeenPolicy.tooltip(["@a:x", "@b:x", "@zoe:x"]) { names[$0] } == "Seen by Alice, Bob and zoe")
        let four = SeenPolicy.tooltip(["@a:x", "@b:x", "@c:x", "@d:x"]) { names[$0] }
        #expect(four == "Seen by Alice, Bob and 2 others")
    }
}
