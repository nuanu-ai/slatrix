import Foundation
import Testing

@testable import Slatrix

struct MessageReplyTargetTests {
    private static let room = "!room:example.org"
    private static let root = "$root"
    private static let owner = MessageReplyTarget.Owner(userID: "@me:example.org", sessionID: UUID())
    private static func message(id: String = "$original", thread: String? = nil) -> ChatMessage {
        ChatMessage(
            id: id, roomID: room, senderID: "@other:example.org", senderName: "Other", body: "Quoted body",
            timestamp: .distantPast, threadRootID: thread)
    }
    private static func authorizes(
        _ captured: MessageReplyTarget?, current: MessageReplyTarget?, owner: MessageReplyTarget.Owner = owner,
        room: String = room, thread: String? = nil
    ) -> Bool {
        MessageReplyTarget.authorizes(captured, current: current, owner: owner, roomID: room, threadID: thread)
    }

    static let notQuotableChanges: [@Sendable (inout ChatMessage) -> Void] = [
        { $0.isRedacted = true }, { $0.sendState = "sending" }, { $0.id = "transaction" },
    ]

    @Test("A room quote goes only to its own room composer")
    func roomQuoteScope() throws {
        let quote = try #require(MessageReplyTarget(message: Self.message(), surface: .conversation, owner: Self.owner))
        #expect(quote.surface == .conversation && quote.message.id == "$original")
        #expect(Self.authorizes(quote, current: quote))
        #expect(!Self.authorizes(quote, current: quote, thread: Self.root))
        #expect(!Self.authorizes(quote, current: quote, room: "!other:example.org"))
    }

    @Test("A thread send stays unquoted while a room quote is open, but a room send queued before the quote does not")
    func unquotedSends() throws {
        let quote = try #require(MessageReplyTarget(message: Self.message(), surface: .conversation, owner: Self.owner))
        #expect(Self.authorizes(nil, current: quote, thread: Self.root))
        #expect(!Self.authorizes(nil, current: quote))
    }

    @Test("Quoting a thread reply from anywhere sends it to that thread with the reply as the quote")
    func threadReplyQuote() throws {
        let reply = Self.message(id: "$thread-reply", thread: Self.root)
        let historical = try #require(MessageReplyTarget(message: reply, surface: .conversation, owner: Self.owner))
        let inThread = try #require(
            MessageReplyTarget(message: reply, surface: .thread(rootID: Self.root), owner: Self.owner))
        #expect(historical.surface == .thread(rootID: Self.root) && historical.message.id == "$thread-reply")
        #expect(inThread.surface == historical.surface)
        #expect(!Self.authorizes(historical, current: historical))
        #expect(Self.authorizes(historical, current: historical, thread: Self.root))
    }

    @Test("A thread can quote its root but not an unrelated message")
    func threadScope() throws {
        let rootQuote = try #require(
            MessageReplyTarget(
                message: Self.message(id: Self.root), surface: .thread(rootID: Self.root), owner: Self.owner))
        #expect(rootQuote.threadID == Self.root)
        #expect(
            MessageReplyTarget(message: Self.message(), surface: .thread(rootID: Self.root), owner: Self.owner) == nil)
    }

    @Test("A late completion of a cancelled quote can neither send nor clear a reopened quote of the same message")
    func reopenedQuote() throws {
        let old = try #require(MessageReplyTarget(message: Self.message(), surface: .conversation, owner: Self.owner))
        var active: MessageReplyTarget? = old
        #expect(old.finish(current: &active, owner: Self.owner) && active == nil)
        active = MessageReplyTarget(message: Self.message(), surface: .conversation, owner: Self.owner)
        #expect(!old.finish(current: &active, owner: Self.owner) && active != nil)
        #expect(!Self.authorizes(old, current: active))
    }

    @Test(
        "Work from a previous sign-in or account can neither send nor clear the current quote",
        arguments: [
            MessageReplyTarget.Owner(userID: "@me:example.org", sessionID: UUID()),
            MessageReplyTarget.Owner(userID: "@another:example.org", sessionID: owner.sessionID),
            MessageReplyTarget.Owner(userID: nil, sessionID: owner.sessionID),
        ])
    func staleOwner(changed: MessageReplyTarget.Owner) throws {
        let quote = try #require(MessageReplyTarget(message: Self.message(), surface: .conversation, owner: Self.owner))
        var active: MessageReplyTarget? = quote
        #expect(!Self.authorizes(quote, current: active, owner: changed))
        #expect(!quote.finish(current: &active, owner: changed) && active?.id == quote.id)
    }

    @Test(
        "Deleted, unsent and local-only messages cannot be quoted",
        arguments: notQuotableChanges)
    func notQuotable(change: @Sendable (inout ChatMessage) -> Void) {
        var message = Self.message()
        change(&message)
        #expect(MessageReplyTarget(message: message, surface: .conversation, owner: Self.owner) == nil)
    }
}
