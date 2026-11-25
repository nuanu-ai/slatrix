import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

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
        #expect(message.isRedacted && message.body == "This message was deleted.")
        #expect(message.attachment == nil && message.formattedBody == nil)
    }

    // capability: message.deleted
    @Test(
        "A deleted timeline item strips reactions, reply previews and thread summaries while keeping thread membership")
    func redactedDropsStaleExtras() {
        final class FakeSummary: ThreadSummary, @unchecked Sendable {
            override func numReplies() -> UInt64 { 3 }
            override func latestEvent() -> EmbeddedEventDetails { .unavailable }
        }
        let quote = ReplyDetails(id: "$quoted", details: ready(content("Original")))
        let redacted = MsgLikeContent(
            kind: .redacted, inReplyTo: quote, threadRoot: "$root", threadSummary: FakeSummary(noHandle: .init()))
        let item = EventTimelineItem(
            isRemote: true, eventOrTransactionId: .eventId(eventId: "$gone"),
            sender: "@alice:example.org", senderProfile: .unavailable, forwarder: nil, forwarderProfile: nil,
            isOwn: false, isEditable: false, content: .msgLike(content: redacted),
            reactions: [
                Reaction(
                    key: "👍",
                    senders: [ReactionSenderData(senderId: "@bob:example.org", timestamp: 0, sendState: nil)])
            ], eventTypeRaw: "m.room.message", timestamp: 2_000, localSendState: nil, editSendState: nil,
            redactionSendState: nil, localCreatedAt: nil, readReceipts: [:], origin: nil, canBeRepliedTo: false,
            lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
        let mapped = MatrixMapping.message(item, roomID: "!room:example.org", ownUserID: "@me:example.org")
        #expect(mapped?.isRedacted == true)
        #expect(mapped?.body == ChatMessage.deletedBody)
        #expect(mapped?.threadRootID == "$root")
        #expect(mapped?.reactions.isEmpty == true)
        #expect(mapped?.replyToID == nil && mapped?.replyPreview == nil)
        #expect(mapped?.replyCount == nil && mapped?.lastReply == nil)
        #expect(mapped?.attachment == nil && mapped?.formattedBody == nil)
    }

    @Test("A sender reads as their localpart until the profile resolves, and a shared name carries the ID")
    func profileName() {
        #expect(MatrixMapping.profileName(.pending, userID: "@alice:example.org") == "alice")
        #expect(
            MatrixMapping.profileName(
                .ready(displayName: "Alice", displayNameAmbiguous: true, avatarUrl: nil, status: nil, call: nil),
                userID: "@alice:example.org") == "Alice (@alice:example.org)")
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
        #expect(message?.senderName == "alice")
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

    @Test(
        "Upload progress projects independently of ChatMessage, while pending edits and deletions project onto ChatMessage"
    )
    func uploadProgressAndPendingChanges() {
        func makeItem(
            local: EventSendState? = nil, edit: EventSendState? = nil, redaction: EventSendState? = nil
        ) -> EventTimelineItem {
            EventTimelineItem(
                isRemote: local == nil,
                eventOrTransactionId: local == nil ? .eventId(eventId: "$ev") : .transactionId(transactionId: "tx"),
                sender: "@alice:example.org", senderProfile: .unavailable, forwarder: nil, forwarderProfile: nil,
                isOwn: true, isEditable: true, content: .msgLike(content: content()), reactions: [],
                eventTypeRaw: "m.room.message", timestamp: 0, localSendState: local, editSendState: edit,
                redactionSendState: redaction, localCreatedAt: nil, readReceipts: [:], origin: nil,
                canBeRepliedTo: true, lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
        }
        let halfState = EventSendState.notSentYet(
            progress: MediaUploadProgress(index: 0, progress: AbstractProgress(current: 50, total: 100)))
        let fullState = EventSendState.notSentYet(
            progress: MediaUploadProgress(index: 0, progress: AbstractProgress(current: 90, total: 100)))
        let zeroTotal = EventSendState.notSentYet(
            progress: MediaUploadProgress(index: 0, progress: AbstractProgress(current: 10, total: 0)))
        #expect(MatrixMapping.uploadProgress(from: halfState) == 0.5)
        #expect(MatrixMapping.uploadProgress(from: zeroTotal) == nil)
        // Progress ticks must NOT mutate ChatMessage so TimelineLayout and cached row heights stay untouched.
        let m1 = MatrixMapping.message(makeItem(local: halfState), roomID: "!r", ownUserID: "@alice:example.org")
        let m2 = MatrixMapping.message(makeItem(local: fullState), roomID: "!r", ownUserID: "@alice:example.org")
        #expect(m1 == m2)

        let editing = MatrixMapping.message(
            makeItem(edit: .notSentYet(progress: nil)), roomID: "!r", ownUserID: "@alice:example.org")
        #expect(editing?.pendingChange == .editing)

        let edited = MatrixMapping.message(
            makeItem(edit: .sent(eventId: "$edit")), roomID: "!r", ownUserID: "@alice:example.org")
        #expect(edited?.pendingChange == nil)

        let deleting = MatrixMapping.message(
            makeItem(edit: .notSentYet(progress: nil), redaction: .notSentYet(progress: nil)),
            roomID: "!r", ownUserID: "@alice:example.org")
        #expect(deleting?.pendingChange == .deleting)
    }

    @Test("Undecryptable messages map UtdCause truthfully and only mark unlockable causes as unlockable")
    func unableToDecryptMapsCause() {
        func utd(_ encrypted: EncryptedMessage) -> ChatMessage {
            project(
                MsgLikeContent(
                    kind: .unableToDecrypt(msg: encrypted), inReplyTo: nil, threadRoot: nil, threadSummary: nil))
        }
        let cases: [(EncryptedMessage, String, Bool)] = [
            (.megolmV1AesSha2(sessionId: "s", cause: .sentBeforeWeJoined), "Sent before you joined", false),
            (
                .megolmV1AesSha2(sessionId: "s", cause: .historicalMessageAndBackupIsDisabled),
                "History isn’t available on this device", false
            ),
            (
                .megolmV1AesSha2(sessionId: "s", cause: .historicalMessageAndDeviceIsUnverified),
                "Verify this device to read", true
            ),
            (
                .megolmV1AesSha2(sessionId: "s", cause: .withheldForUnverifiedOrInsecureDevice),
                "Verify this device to read", true
            ),
            (
                .megolmV1AesSha2(sessionId: "s", cause: .withheldBySender),
                "The sender didn’t share this message with this device", false
            ),
            (.megolmV1AesSha2(sessionId: "s", cause: .verificationViolation), "Sent by an unverified session", false),
            (.megolmV1AesSha2(sessionId: "s", cause: .unsignedDevice), "Sent by an unverified device", false),
            (.megolmV1AesSha2(sessionId: "s", cause: .unknownDevice), "Sent by an unknown device", false),
            (.megolmV1AesSha2(sessionId: "s", cause: .unknown), "Waiting for keys…", true),
            (.olmV1Curve25519AesSha2(senderKey: "k"), "Waiting for keys…", true),
            (.unknown, "Waiting for keys…", true),
        ]
        for (encrypted, expectedBody, unlockable) in cases {
            let mapped = utd(encrypted)
            #expect(mapped.kind == "m.room.encrypted")
            #expect(mapped.body == expectedBody)
            #expect(mapped.isUnlockable == unlockable)
        }
        let reply = MatrixMapping.replyPreview(
            eventID: "$quoted",
            details: ready(
                MsgLikeContent(
                    kind: .unableToDecrypt(msg: .megolmV1AesSha2(sessionId: "s", cause: .sentBeforeWeJoined)),
                    inReplyTo: nil, threadRoot: nil, threadSummary: nil)))
        #expect(reply.body == "Sent before you joined")
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
        #expect(preview.isRedacted && preview.body == "This message was deleted.")
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

    @Test("Plain-text previews sanitize Matrix Markdown mention links, inline backticks and code fences")
    func previewSanitizesMarkdownAndBackticks() {
        let rawMention = "[Dmitry Ukhanov](https://matrix.to/#/@dmitry.ukhanov:example.org) run `swift test`"
        #expect(ActivityService.previewBody(rawMention, formatted: nil) == "@Dmitry Ukhanov run swift test")
        let quote = MatrixMapping.replyPreview(eventID: "$quoted", details: ready(content(rawMention)))
        #expect(quote.body == "@Dmitry Ukhanov run swift test")

        func latest(_ body: String, formatted: FormattedBody? = nil, replyTo: InReplyToDetails? = nil) -> String? {
            let value = LatestEventValue.remote(
                timestamp: 1_000, sender: "@alice:example.org", isOwn: false, profile: .unavailable,
                content: .msgLike(content: content(body, formatted: formatted, replyTo: replyTo)))
            return MatrixMapping.latestMessage(value)?.body
        }
        #expect(latest("Запускаю живой план для `foo`") == "Запускаю живой план для foo")
        #expect(latest(rawMention) == "@Dmitry Ukhanov run swift test")
        #expect(latest("Header\n```swift\nlet x = 1\n```") == "Header let x = 1")
        let reply = ReplyDetails(id: "$orig", details: .unavailable)
        #expect(latest("> <@bob:example.org> Old\n\nNew `reply`", replyTo: reply) == "New reply")
        #expect(
            latest(
                "secret",
                formatted: FormattedBody(format: .html, body: "<span data-mx-spoiler>secret</span>"))
                == "[Spoiler hidden]")
    }
}

struct RepliedToThreadMappingTests {
    struct Quoted: Decodable {
        var sender: String
        var body: String
    }

    struct Shown: Decodable, CustomTestStringConvertible {
        var name: String
        var sender: String
        var body: String
        var inThread: Bool
        var quoted: Quoted?
        var repliedToThread: Bool
        var testDescription: String { name }
    }

    struct Spec: Decodable { var shown: [Shown] }

    // capability: thread.send-to-channel
    @Test(
        "A channel's copy of a thread reply reads as Slack's \"replied to a thread\", from spec/send-to-channel.json",
        arguments: try SharedSpec.decode("spec/send-to-channel.json", as: Spec.self).shown)
    func shown(spec: Shown) {
        let quote = spec.quoted.map { quoted in
            ReplyDetails(
                id: "$reply",
                details: .ready(
                    content: .msgLike(content: content(quoted.body)), sender: quoted.sender,
                    senderProfile: .unavailable, timestamp: 1_000, eventOrTransactionId: .eventId(eventId: "$reply")))
        }
        let message = MatrixMapping.project(
            content(spec.body, threadRoot: spec.inThread ? "$root" : nil, replyTo: quote), id: "$copy",
            roomID: "!room:example.org", senderID: spec.sender, senderName: "Sender", timestamp: 2_000)
        #expect(message.repliedToThread == spec.repliedToThread)
    }
}
