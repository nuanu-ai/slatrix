import Foundation
import Testing

@testable import Slatrix

struct ConversationKeysTests {
    @Test("↑ edits your last message only from an empty composer")
    func upEditsOnlyWhenEmpty() {
        #expect(ConversationKeys.action(.up, shift: false, otherModifiers: false, composerText: "") == .editLastMessage)
        #expect(ConversationKeys.action(.up, shift: false, otherModifiers: false, composerText: "draft") == nil)
        #expect(ConversationKeys.action(.up, shift: true, otherModifiers: false, composerText: "") == nil)
        #expect(ConversationKeys.action(.up, shift: false, otherModifiers: true, composerText: "") == nil)
        #expect(ConversationKeys.action(.up, shift: false, otherModifiers: false, composerText: nil) == nil)
    }

    @Test("Esc marks the conversation read, ⇧Esc marks everything read")
    func escapeMarksRead() {
        #expect(ConversationKeys.action(.escape, shift: false, otherModifiers: false, composerText: "x") == .markRead)
        #expect(ConversationKeys.action(.escape, shift: true, otherModifiers: false, composerText: nil) == .markAllRead)
        #expect(ConversationKeys.action(.escape, shift: false, otherModifiers: true, composerText: nil) == nil)
    }

    @Test("↑ picks your newest sent text message, skipping others' and unsendable ones")
    func lastEditable() {
        func message(_ id: String, from sender: String, _ change: (inout ChatMessage) -> Void = { _ in }) -> ChatMessage
        {
            var message = ChatMessage(
                id: id, roomID: "!room", senderID: sender, senderName: sender, body: id, timestamp: Date())
            change(&message)
            return message
        }
        let messages = [
            message("$mine", from: "@me"),
            message("$deleted", from: "@me") { $0.isRedacted = true },
            message("$image", from: "@me") { $0.kind = "m.image" },
            message("$theirs", from: "@them"),
            message("~sending", from: "@me") { $0.sendState = "sending" },
        ]
        #expect(ConversationKeys.lastEditable(messages, userID: "@me")?.id == "$mine")
        #expect(ConversationKeys.lastEditable(messages, userID: "@nobody") == nil)
        #expect(ConversationKeys.lastEditable(messages, userID: nil) == nil)
    }
}
