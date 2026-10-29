import Testing

@testable import Slatrix

struct MessageJumpTests {
    @Test("A jump to a thread reply shows its root in the conversation and the reply in that thread's pane")
    func threadReply() {
        let jump = MessageJump(roomID: "!room:example.org", eventID: "$reply", threadRootID: "$root")
        #expect(jump.eventID(inThread: nil) == "$root")
        #expect(jump.eventID(inThread: "$root") == "$reply")
        #expect(jump.eventID(inThread: "$other") == nil)
    }

    @Test("A jump to a message in the conversation shows it there and in no thread's pane")
    func conversationMessage() {
        let jump = MessageJump(roomID: "!room:example.org", eventID: "$message")
        #expect(jump.eventID(inThread: nil) == "$message")
        #expect(jump.eventID(inThread: "$message") == nil)
    }
}
