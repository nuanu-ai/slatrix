import Foundation
import Testing

@testable import Slatrix

/// Every message action (react, edit, delete, reply preview, caption, forward) captures this context and is
/// rejected once any part of it changes.
struct MessageActionTargetTests {
    private static let session = UUID()
    private static let timeline = UUID()
    private static let threadSelection = UUID()
    private static let presentation = UUID()

    private static func context(
        session: UUID = session, userID: String? = "@owner:example.org", roomID: String? = "!room:example.org",
        timeline: UUID = timeline, threadSelection: UUID = threadSelection, presentation: UUID = presentation,
        readyThreadID: String? = "$root", authenticated: Bool = true, joined: Bool = true, preview: Bool = false
    ) -> MessageActionTarget.Context {
        .init(
            sessionID: session, userID: userID, roomID: roomID, timelineID: timeline,
            threadSelectionID: threadSelection, threadPresentationID: presentation, readyThreadID: readyThreadID,
            authenticated: authenticated, joined: joined, preview: preview)
    }
    private static func message(_ id: String = "$reply", threadRootID: String? = "$root") -> ChatMessage {
        var value = ChatMessage(
            id: id, roomID: "!room:example.org", senderID: "@owner:example.org", senderName: "Owner", body: "Hi",
            timestamp: Date(timeIntervalSince1970: 0))
        value.threadRootID = threadRootID
        value.replyToID = "$quoted"
        return value
    }

    struct Change: CustomTestStringConvertible, Sendable {
        let testDescription: String
        let context: MessageActionTarget.Context
        /// Whether an action shown in the main timeline survives the change.
        let conversationSurvives: Bool
    }
    static let changes: [Change] = [
        Change(testDescription: "new session", context: context(session: UUID()), conversationSurvives: false),
        Change(
            testDescription: "other account", context: context(userID: "@other:example.org"),
            conversationSurvives: false),
        Change(testDescription: "signed out", context: context(userID: nil), conversationSurvives: false),
        Change(
            testDescription: "other room", context: context(roomID: "!other:example.org"), conversationSurvives: false),
        Change(testDescription: "room reselected", context: context(timeline: UUID()), conversationSurvives: false),
        Change(testDescription: "sync stopped", context: context(authenticated: false), conversationSurvives: false),
        Change(testDescription: "left the room", context: context(joined: false), conversationSurvives: false),
        Change(testDescription: "previewing", context: context(preview: true), conversationSurvives: false),
        Change(
            testDescription: "thread reloaded", context: context(threadSelection: UUID()), conversationSurvives: true),
        Change(testDescription: "thread reopened", context: context(presentation: UUID()), conversationSurvives: true),
        Change(testDescription: "thread closed", context: context(readyThreadID: nil), conversationSurvives: true),
        Change(testDescription: "other thread", context: context(readyThreadID: "$other"), conversationSurvives: true),
    ]

    @Test(
        "A captured action stays current while nothing changes",
        arguments: [MessageActionTarget.Surface.conversation, .thread(rootID: "$root")])
    func currentWhileUnchanged(surface: MessageActionTarget.Surface) throws {
        let target = try #require(
            MessageActionTarget(message: Self.message(), surface: surface, context: Self.context()))
        #expect(target.isCurrent(in: Self.context()))
    }

    @Test("A thread action goes stale on any context change", arguments: changes)
    func threadActionGoesStale(change: Change) throws {
        let target = try #require(
            MessageActionTarget(message: Self.message(), surface: .thread(rootID: "$root"), context: Self.context()))
        #expect(!target.isCurrent(in: change.context))
    }

    @Test(
        "A main-timeline action ignores thread pane changes but not account, room or session changes",
        arguments: changes)
    func conversationActionScope(change: Change) throws {
        let target = try #require(
            MessageActionTarget(message: Self.message(), surface: .conversation, context: Self.context()))
        #expect(target.isCurrent(in: change.context) == change.conversationSurvives)
    }

    @Test(
        "Only sent remote messages in a usable room can be acted on",
        arguments: [
            ("local echo", message("transaction-id"), context()),
            (
                "sending",
                {
                    var value = message()
                    value.sendState = "sending"
                    return value
                }(), context()
            ),
            (
                "deleted",
                {
                    var value = message()
                    value.isRedacted = true
                    return value
                }(), context()
            ),
            (
                "other room",
                {
                    var value = message()
                    value.roomID = "!other:example.org"
                    return value
                }(), context()
            ),
            ("signed out", message(), context(userID: nil)),
            ("sync stopped", message(), context(authenticated: false)),
            ("not joined", message(), context(joined: false)),
            ("previewing", message(), context(preview: true)),
        ])
    func ineligibleMessages(label: String, message: ChatMessage, context: MessageActionTarget.Context) {
        #expect(MessageActionTarget(message: message, surface: .conversation, context: context) == nil)
    }

    @Test(
        "A thread action needs that thread ready and a message that belongs to it",
        arguments: [
            ("thread not ready", message(), context(readyThreadID: nil)),
            ("other thread ready", message(), context(readyThreadID: "$other")),
            ("reply in another thread", message(threadRootID: "$other"), context()),
            ("unthreaded message", message(threadRootID: nil), context()),
        ])
    func threadEligibility(label: String, message: ChatMessage, context: MessageActionTarget.Context) {
        #expect(MessageActionTarget(message: message, surface: .thread(rootID: "$root"), context: context) == nil)
    }

    @Test("The thread root itself can be acted on in its thread although it has no thread relation")
    func rootInItsThread() {
        let root = Self.message("$root", threadRootID: nil)
        #expect(MessageActionTarget(message: root, surface: .thread(rootID: "$root"), context: Self.context()) != nil)
    }

    @Test("Re-rendering an action keeps its reply preview identity; reopening its thread pane does not")
    func replyPreviewIdentity() throws {
        let thread = MessageActionTarget.Surface.thread(rootID: "$root")
        let first = try #require(MessageActionTarget(message: Self.message(), surface: thread, context: Self.context()))
        let again = try #require(MessageActionTarget(message: Self.message(), surface: thread, context: Self.context()))
        let reopened = try #require(
            MessageActionTarget(message: Self.message(), surface: thread, context: Self.context(presentation: UUID())))
        #expect(first.id != again.id)
        #expect(first.replyPreviewIdentity != nil && first.replyPreviewIdentity == again.replyPreviewIdentity)
        #expect(reopened.replyPreviewIdentity != first.replyPreviewIdentity)
    }

    @Test("A main-timeline reply preview keeps its identity when a thread pane opens or closes")
    func conversationReplyPreviewIdentity() throws {
        let before = try #require(
            MessageActionTarget(message: Self.message(), surface: .conversation, context: Self.context()))
        let after = try #require(
            MessageActionTarget(
                message: Self.message(), surface: .conversation,
                context: Self.context(presentation: UUID(), readyThreadID: nil)))
        #expect(before.replyPreviewIdentity == after.replyPreviewIdentity)
    }
}
