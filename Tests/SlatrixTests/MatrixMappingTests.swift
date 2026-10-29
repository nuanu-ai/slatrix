import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class ReplyDetails: InReplyToDetails, @unchecked Sendable {
    let identifier: String
    let details: EmbeddedEventDetails
    let reads = Recorder<Void>()
    init(id: String, details: EmbeddedEventDetails) {
        identifier = id
        self.details = details
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func eventId() -> String { identifier }
    override func event() -> EmbeddedEventDetails {
        reads.append(())
        return details
    }
}

private func content(
    _ body: String = "Hello", formatted: FormattedBody? = nil, edited: Bool = false, threadRoot: String? = nil,
    replyTo: InReplyToDetails? = nil
) -> MsgLikeContent {
    MsgLikeContent(
        kind: .message(
            content: MessageContent(
                msgType: .text(content: TextMessageContent(body: body, formatted: formatted)), body: body,
                isEdited: edited, mentions: nil)), inReplyTo: replyTo, threadRoot: threadRoot, threadSummary: nil)
}

private func project(_ content: MsgLikeContent, id: String = "$event") -> ChatMessage {
    MatrixMapping.project(
        content, id: id, roomID: "!room:example.org", senderID: "@bob:example.org", senderName: "Bob",
        timestamp: 2_000)
}

private func ready(_ content: MsgLikeContent, id: String = "$quoted") -> EmbeddedEventDetails {
    .ready(
        content: .msgLike(content: content), sender: "@alice:example.org",
        senderProfile: .ready(
            displayName: "Alice", displayNameAmbiguous: false, avatarUrl: nil, status: nil, call: nil),
        timestamp: 1_000, eventOrTransactionId: .eventId(eventId: id))
}

private let redactedContent = MsgLikeContent(kind: .redacted, inReplyTo: nil, threadRoot: nil, threadSummary: nil)

struct MatrixMappingTests {
    // capability: message.edited
    @Test("A message shows the SDK's edited body, its thread, sender name and time")
    func projectsEditedThreadReply() {
        let message = MatrixMapping.project(
            content("Updated answer", edited: true, threadRoot: "$root"), id: "$reply", roomID: "!room:example.org",
            senderID: "@alice:example.org", senderName: "Alice", timestamp: 1_000)
        #expect(message.body == "Updated answer" && message.isEdited)
        #expect(message.threadRootID == "$root")
        #expect(message.timestamp == Date(timeIntervalSince1970: 1))
        #expect(message.senderName == "Alice")
    }

    // capability: message.deleted
    @Test("A deleted message keeps none of its original body, formatting or attachment")
    func redaction() {
        let message = project(redactedContent)
        #expect(message.isRedacted && message.body == "This message was deleted")
        #expect(message.attachment == nil && message.formattedBody == nil)
    }

    @Test("A sender's name falls back to their ID until the profile resolves")
    func profileName() {
        #expect(MatrixMapping.profileName(.pending, fallback: "@alice:example.org") == "@alice:example.org")
        #expect(
            MatrixMapping.profileName(
                .ready(displayName: "Alice", displayNameAmbiguous: false, avatarUrl: nil, status: nil, call: nil),
                fallback: "@alice:example.org") == "Alice")
    }

    // capability: message.reactions.show
    @Test("A queued local echo shows as sending, with reactions counted and mine marked")
    func queuedEchoAndReactions() {
        let item = EventTimelineItem(
            isRemote: false, eventOrTransactionId: .transactionId(transactionId: "local"),
            sender: "@alice:example.org", senderProfile: .unavailable, forwarder: nil, forwarderProfile: nil,
            isOwn: true, isEditable: true, content: .msgLike(content: content()),
            reactions: [
                Reaction(
                    key: "👍",
                    senders: [
                        ReactionSenderData(senderId: "@alice:example.org", timestamp: 0, sendState: nil),
                        ReactionSenderData(senderId: "@bob:example.org", timestamp: 0, sendState: nil),
                    ])
            ], eventTypeRaw: "m.room.message", timestamp: 0, localSendState: .notSentYet(progress: nil),
            editSendState: nil, redactionSendState: nil, localCreatedAt: nil, readReceipts: [:], origin: nil,
            canBeRepliedTo: true, lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
        let message = MatrixMapping.message(item, roomID: "!room:example.org", ownUserID: "@alice:example.org")
        #expect(message?.id == "local" && message?.sendState == "sending")
        #expect(
            message?.reactions == [
                MessageReaction(
                    key: "👍", count: 2, mine: true, senders: ["@alice:example.org", "@bob:example.org"])
            ])
        #expect(message?.senderName == "@alice:example.org")
    }

    @Test(
        "Originals up to 10 MiB preview automatically; larger or unknown sizes need an explicit download",
        arguments: [(nil, false), (10 * 1024 * 1024, true), (10 * 1024 * 1024 + 1, false)] as [(UInt64?, Bool)])
    func automaticPreviewLimit(size: UInt64?, allowed: Bool) {
        #expect(MatrixMapping.permitsAutomaticOriginalPreview(size: size) == allowed)
    }

    @Test("Only an explicit HTML format is kept as formatted text; other formats fall back to the plain body")
    func formattedBody() {
        let html = project(content("Plain fallback", formatted: FormattedBody(format: .html, body: "<b>Rich body</b>")))
        let unknown = project(
            content(
                "Literal <tag>", formatted: FormattedBody(format: .unknown(format: "example.custom"), body: "<b>x</b>"))
        )
        #expect(html.formattedBody == "<b>Rich body</b>")
        #expect(unknown.formattedBody == nil && unknown.body == "Literal <tag>")
    }
}

struct ReplyPreviewMappingTests {
    // capability: message.reply-preview
    @Test("A reply shows its quoted sender and literal body, without reading the quote's own reply")
    func leafReply() {
        let nested = ReplyDetails(id: "$nested", details: .pending)
        let quote = ReplyDetails(
            id: "$quoted", details: ready(content("> Literal quotation\n\nKeep this text", replyTo: nested)))
        let reply = project(content("My reply", replyTo: quote))
        #expect(reply.replyToID == "$quoted")
        #expect(reply.replyPreview?.state == .ready && reply.replyPreview?.senderName == "Alice")
        #expect(reply.replyPreview?.body == "> Literal quotation\n\nKeep this text")
        #expect(nested.reads.all.isEmpty)
    }

    @Test("Explicitly quoting the thread root keeps the quote")
    func quotingThreadRoot() {
        let quote = ReplyDetails(id: "$quoted", details: ready(content("Root")))
        let message = project(content("Quote of root", threadRoot: "$quoted", replyTo: quote))
        #expect(message.threadRootID == "$quoted" && message.replyPreview?.eventID == "$quoted")
    }

    @Test("A thread reply without an explicit quote has no quote preview")
    func threadFallbackHasNoQuote() {
        let message = project(content("Thread fallback", threadRoot: "$quoted"))
        #expect(message.threadRootID == "$quoted" && message.replyToID == nil && message.replyPreview == nil)
    }

    @Test(
        "Pending and unavailable quotes keep their state",
        arguments: [(EmbeddedEventDetails.pending, ChatReplyPreview.State.pending), (.unavailable, .unavailable)])
    func pendingAndUnavailable(details: EmbeddedEventDetails, state: ChatReplyPreview.State) {
        #expect(MatrixMapping.replyPreview(eventID: "$quoted", details: details).state == state)
    }

    @Test("A quote that failed to load does not show the SDK's error details")
    func failedQuote() {
        let preview = MatrixMapping.replyPreview(
            eventID: "$quoted", details: .error(message: "private-request-details"))
        #expect(preview.state == .failed && !preview.body.contains("private-request-details"))
    }

    @Test("A deleted quote keeps none of its original content")
    func redactedQuote() {
        let preview = MatrixMapping.replyPreview(eventID: "$quoted", details: ready(redactedContent))
        #expect(preview.isRedacted && preview.body == "This message was deleted")
    }

    @Test("Quote and Activity previews show a mention as @Name, never its link or raw ID")
    func previewMentions() {
        let body = "[Alice](https://matrix.to/#/@alice:example.org) look"
        let html = FormattedBody(
            format: .html, body: "<a href=\"https://matrix.to/#/@alice:example.org\">Alice</a> look")
        let quote = MatrixMapping.replyPreview(eventID: "$quoted", details: ready(content(body, formatted: html)))
        #expect(quote.body == "@Alice look")
        #expect(ActivityService.previewBody(body, formatted: html) == "@Alice look")
        #expect(ActivityService.previewBody("ping @bob:example.org", formatted: nil) == "ping @bob")
    }

    @Test("A quoted spoiler stays hidden")
    func spoilerQuote() {
        let spoiler = content(
            "Hidden answer", formatted: FormattedBody(format: .html, body: "<span data-mx-spoiler>Hidden answer</span>")
        )
        #expect(MatrixMapping.replyPreview(eventID: "$spoiler", details: ready(spoiler)).body == "[Spoiler hidden]")
    }
}
