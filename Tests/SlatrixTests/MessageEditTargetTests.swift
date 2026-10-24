import Foundation
import Testing

@testable import Slatrix

struct MessageEditTargetTests {
    private static let session = UUID()
    private static let timeline = UUID()
    private static let roomID = "!room:example.org"
    private static let rootID = "$thread"
    private static func context(
        session: UUID = session, user: String = "@me:example.org", room: String = roomID, timeline: UUID = timeline,
        thread: String? = nil, ready: String? = nil
    ) -> MessageEditTarget.Context {
        .init(
            sessionID: session, userID: user, roomID: room, timelineID: timeline, threadID: thread, readyThreadID: ready
        )
    }
    private static let main = context()
    private static let thread = context(thread: rootID, ready: rootID)
    private static func message(id: String = "$original", thread: String? = nil) -> ChatMessage {
        ChatMessage(
            id: id, roomID: roomID, senderID: "@me:example.org", senderName: "Me", body: "Original",
            timestamp: .distantPast, threadRootID: thread)
    }

    static let notEditableChanges: [@Sendable (inout ChatMessage) -> Void] = [
        { $0.isRedacted = true }, { $0.sendState = "sending" }, { $0.senderID = "@other:example.org" },
        { $0.kind = "m.notice" }, { $0.kind = "m.emote" }, { $0.kind = "m.image" }, { $0.kind = "m.file" },
        { $0.kind = "m.poll" }, { $0.kind = "m.location" }, { $0.kind = "unknown" },
        { $0.attachment = MessageAttachment(name: "Photo", url: "mxc://example.org/photo") },
    ]

    @Test("Your own sent text message can be edited and saved from the conversation")
    func editsOwnMessage() throws {
        let target = try #require(
            MessageEditTarget(message: Self.message(), surface: .conversation, context: Self.main))
        var text = "Changed"
        #expect(target.write("Saved text", current: target, context: Self.main, text: &text))
        #expect(text == "Saved text")
    }

    @Test("A late save of a cancelled edit cannot empty a reopened edit of the same message")
    func reopenedEditIgnoresOldSave() throws {
        let old = try #require(MessageEditTarget(message: Self.message(), surface: .conversation, context: Self.main))
        var current: MessageEditTarget? = old
        var text = "Changed"
        old.finish(current: &current, context: Self.main, text: &text)
        #expect(current == nil && text.isEmpty)
        current = MessageEditTarget(message: Self.message(), surface: .conversation, context: Self.main)
        text = "New edit of the same event"
        old.write("", current: current, context: Self.main, text: &text)
        old.finish(current: &current, context: Self.main, text: &text)
        #expect(text == "New edit of the same event" && current != nil)
    }

    @Test(
        "A save that completes after the account, sign-in, room or timeline changed leaves the edit alone",
        arguments: [
            context(session: UUID()), context(user: "@other:example.org"), context(room: "!other:example.org"),
            context(timeline: UUID()),
        ])
    func staleContext(changed: MessageEditTarget.Context) throws {
        let target = try #require(
            MessageEditTarget(message: Self.message(), surface: .conversation, context: Self.main))
        var current: MessageEditTarget? = target
        var text = "Retained edit"
        #expect(!target.isCurrent(current, in: changed))
        target.write("", current: current, context: changed, text: &text)
        target.finish(current: &current, context: changed, text: &text)
        #expect(current?.id == target.id && text == "Retained edit")
    }

    @Test("A thread reply edited from the conversation stays in the conversation and edits the reply")
    func historicalReply() throws {
        let target = try #require(
            MessageEditTarget(
                message: Self.message(id: "$reply", thread: Self.rootID), surface: .conversation, context: Self.main))
        #expect(target.surface == .conversation && target.message.id == "$reply")
    }

    @Test(
        "A thread edit stops being current when the thread closes or reloads",
        arguments: [main, context(thread: rootID, ready: nil)])
    func threadEditNeedsReadyThread(changed: MessageEditTarget.Context) throws {
        let target = try #require(
            MessageEditTarget(
                message: Self.message(id: "$reply", thread: Self.rootID), surface: .thread(rootID: Self.rootID),
                context: Self.thread))
        #expect(target.isCurrent(target, in: Self.thread))
        #expect(!target.isCurrent(target, in: changed))
    }

    @Test("A thread panel can edit its root but not a message outside the thread")
    func threadPanelScope() throws {
        let root = try #require(
            MessageEditTarget(
                message: Self.message(id: Self.rootID), surface: .thread(rootID: Self.rootID), context: Self.thread))
        #expect(root.surface == .thread(rootID: Self.rootID))
        #expect(
            MessageEditTarget(message: Self.message(), surface: .thread(rootID: Self.rootID), context: Self.thread)
                == nil)
    }

    @Test(
        "Deleted, unsent, other people's and non-text messages cannot be edited",
        arguments: notEditableChanges)
    func notEditable(change: @Sendable (inout ChatMessage) -> Void) {
        var message = Self.message()
        change(&message)
        #expect(MessageEditTarget(message: message, surface: .conversation, context: Self.main) == nil)
    }
}
