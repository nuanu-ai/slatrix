import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private let destinationID = "!destination:example.org"
private let richText = MessageType.text(
    content: TextMessageContent(
        body: "**literal**, @room and @mentioned:example.org",
        formatted: FormattedBody(format: .html, body: "<strong>rich</strong> <span data-mx-spoiler>hidden</span>")))

/// Forwarding a thread root (shown only in its thread pane) from an encrypted room to another joined room.
@MainActor
private final class Forwarding {
    let f: ActionFixture
    let destination = ActionRoom(id: destinationID)
    var service: MatrixService { f.service }
    var sent: [String] { destination.timeline.writes.all }
    private(set) var message: ChatMessage

    init(_ type: MessageType = richText, sender: String = "@original:example.org", inThread: Bool = true) {
        f = ActionFixture(otherRooms: [destination])
        f.service.rooms.append(ChatRoom(id: destinationID, name: "Destination", isEncrypted: true))
        message = f.message(f.rootID)
        f.service.messages = []
        f.service.threadMessages = []
        publish(messageEvent(f.rootID, type: type, sender: sender, own: sender == f.userID), inThread: inThread)
    }

    /// Shows `event` in a pane through the real projection and makes the SDK return it.
    func publish(_ event: EventTimelineItem, inThread: Bool = true) {
        message = MatrixMapping.message(event, roomID: f.roomID, ownUserID: f.userID)!
        (inThread ? f.thread : f.main).event = event
        f.service.projectMediaCaptionForChecks([FakeTimelineItem(event)], roomID: f.roomID, inThread: inThread)
    }
    func target(inThread: Bool = true) throws -> MessageActionTarget {
        try f.target(message, inThread ? .thread(rootID: f.rootID) : .conversation)
    }
    func review(inThread: Bool = true) async throws -> ForwardMessageReview {
        try await service.loadForwardMessage(target(inThread: inThread))
    }
    func forward(_ review: ForwardMessageReview) async throws -> ForwardMessageQueuedResult {
        try await service.forwardMessage(review, to: destinationID)
    }
}

@MainActor
struct ForwardMessageTests {
    // capability: message.forward
    @Test("Forwarding a thread root sends its typed content once to a live destination timeline")
    func forwardsThreadRoot() async throws {
        let forwarding = Forwarding()
        let review = try await forwarding.review()
        guard case .text(let text) = review.value else {
            Issue.record("expected text")
            return
        }
        #expect(text.body == "**literal**, @room and @mentioned:example.org")
        #expect(text.formatted?.body.contains("data-mx-spoiler") == true)

        let result = try await forwarding.forward(review)
        #expect(result.destinationRoomID == destinationID && result.reviewID == review.id)
        #expect(forwarding.sent == ["send"])
        let configuration = try #require(forwarding.destination.configurations.all.first)
        #expect(configuration.focus == .live(hideThreadedEvents: true))
        #expect(configuration.trackReadReceipts == .disabled)
        #expect(forwarding.f.thread.writes.all.isEmpty && forwarding.f.main.writes.all.isEmpty)
        #expect(forwarding.f.main.reads.all.isEmpty && !forwarding.f.thread.reads.all.isEmpty)
        #expect(forwarding.service.selectedRoomID == forwarding.f.roomID)
    }

    @Test("A thread reply shown in the main timeline is read from the main timeline")
    func mainReplyReadsMain() async throws {
        let forwarding = Forwarding(inThread: false)
        _ = try await forwarding.forward(try await forwarding.review(inThread: false))
        #expect(!forwarding.f.main.reads.all.isEmpty && forwarding.f.thread.reads.all.isEmpty)
        #expect(forwarding.sent == ["send"])
    }

    @Test(
        "Notices and emotes keep their message type",
        arguments: [
            MessageType.notice(content: NoticeMessageContent(body: "Notice **not Markdown**", formatted: nil)),
            .emote(
                content: EmoteMessageContent(
                    body: "waves", formatted: FormattedBody(format: .html, body: "<em>waves</em>"))),
        ])
    func keepsMessageType(type: MessageType) async throws {
        let forwarding = Forwarding(type)
        let review = try await forwarding.review()
        let expected = try ForwardMessageContent(
            MessageContent(msgType: type, body: "", isEdited: false, mentions: nil))
        #expect(review.value == expected)
        _ = try await forwarding.forward(review)
        #expect(forwarding.sent == ["send"])
    }

    enum Unforwardable: String, CaseIterable, CustomTestStringConvertible {
        case deleted, customType, localEcho, otherEvent, otherSender, pendingEdit, pendingDeletion
        var testDescription: String { rawValue }
    }

    @Test("A source the SDK reports as unforwardable is refused", arguments: Unforwardable.allCases)
    func refusesUnforwardableSource(reason: Unforwardable) async throws {
        let forwarding = Forwarding()
        var event = try #require(forwarding.f.thread.event)
        switch reason {
        case .deleted:
            event.content = .msgLike(
                content: MsgLikeContent(kind: .redacted, inReplyTo: nil, threadRoot: nil, threadSummary: nil))
        case .customType: event = messageEvent("$root", type: .other(msgtype: "m.custom", body: "Custom"), own: false)
        case .localEcho: event.isRemote = false
        case .otherEvent: event.eventOrTransactionId = .eventId(eventId: "$another")
        case .otherSender: event.sender = "@forged:example.org"
        case .pendingEdit: event.editSendState = .notSentYet(progress: nil)
        case .pendingDeletion: event.redactionSendState = .notSentYet(progress: nil)
        }
        forwarding.f.thread.event = event
        await #expect(throws: (any Error).self) { try await forwarding.review() }
    }

    @Test(
        "An edit that lands before sending returns a fresh review and sends nothing until it is confirmed",
        arguments: [false, true])
    func editRequiresFreshReview(duringDestinationSetup: Bool) async throws {
        let forwarding = Forwarding()
        let old = try await forwarding.review()
        let edited = messageEvent(
            "$root", type: .text(content: TextMessageContent(body: "Edited body", formatted: nil)),
            sender: "@original:example.org", own: false)
        if duringDestinationSetup {
            // The first read checks the review; the edit lands before the re-read after destination setup.
            forwarding.f.thread.onRead = { [weak forwarding] in
                if forwarding?.destination.configurations.all.isEmpty == false { forwarding?.f.thread.event = edited }
            }
        } else {
            forwarding.f.thread.event = edited
        }
        do {
            _ = try await forwarding.forward(old)
            Issue.record("a changed source must not be sent")
        } catch let changed as ForwardMessageReviewChanged {
            #expect(changed.review.value != old.value && forwarding.sent.isEmpty)
            _ = try await forwarding.forward(changed.review)
            #expect(forwarding.sent == ["send"])
        }
    }

    enum Destination: String, CaseIterable, CustomTestStringConvertible {
        case left, unencrypted, unknownEncryption, encryptionUnavailable, noPermission, invited, space
        var testDescription: String { rawValue }
    }

    @Test(
        "An encrypted message is never forwarded to a room it cannot safely be sent to",
        arguments: Destination.allCases)
    func refusesUnsafeDestination(reason: Destination) async throws {
        let forwarding = Forwarding()
        let review = try await forwarding.review()
        switch reason {
        case .left: forwarding.destination.joined = false
        case .unencrypted: forwarding.destination.encryption = .notEncrypted
        case .unknownEncryption: forwarding.destination.encryption = .unknown
        case .encryptionUnavailable: forwarding.destination.failsEncryption = true
        case .noPermission: forwarding.destination.powers.canSend = false
        case .invited: forwarding.service.rooms[1].membership = "invite"
        case .space: forwarding.service.rooms[1].isSpace = true
        }
        await #expect(throws: (any Error).self) { try await forwarding.forward(review) }
        #expect(forwarding.sent.isEmpty)
    }

    @Test("A message from an unencrypted room can go to an unencrypted room")
    func unencryptedToUnencrypted() async throws {
        let forwarding = Forwarding()
        let review = try await forwarding.review()
        forwarding.f.room.encryption = .notEncrypted
        forwarding.destination.encryption = .notEncrypted
        _ = try await forwarding.forward(review)
        #expect(forwarding.sent == ["send"])
    }

    @Test("A send the SDK rejects can be retried")
    func rejectedSendIsRetryable() async throws {
        let forwarding = Forwarding()
        let review = try await forwarding.review()
        forwarding.destination.timeline.failsWrites = true
        await #expect(throws: MatrixServiceError.self) { try await forwarding.forward(review) }
        forwarding.destination.timeline.failsWrites = false
        _ = try await forwarding.forward(review)
        #expect(forwarding.sent == ["send", "send"])
    }

    enum Staleness: String, CaseIterable, CustomTestStringConvertible {
        case session, sourceLeft, sourceRemoved, cancelled
        var testDescription: String { rawValue }
    }

    @Test("A forward whose source went stale during destination setup sends nothing", arguments: Staleness.allCases)
    func staleForwardSendsNothing(change: Staleness) async throws {
        let forwarding = Forwarding()
        let review = try await forwarding.review()
        forwarding.destination.setupGate.arm()
        let pending = Task { try await forwarding.forward(review) }
        #expect(await eventually { forwarding.destination.setupGate.isWaiting })
        switch change {
        case .session: forwarding.f.apply(.session)
        case .sourceLeft: forwarding.f.apply(.left)
        case .sourceRemoved: forwarding.service.threadMessages = []
        case .cancelled: pending.cancel()
        }
        forwarding.destination.setupGate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(forwarding.sent.isEmpty && forwarding.service.errorMessage == nil)
    }

    @Test("Submitting the same review again while it is sending is refused as busy")
    func duplicateSubmitIsBusy() async throws {
        let forwarding = Forwarding()
        let review = try await forwarding.review()
        forwarding.destination.timeline.gate.arm()
        let first = Task { try await forwarding.forward(review) }
        #expect(await eventually { forwarding.destination.timeline.gate.isWaiting })
        await #expect(throws: ForwardMessageError.busy) { try await forwarding.forward(review) }
        forwarding.destination.timeline.gate.release()
        _ = try await first.value
        #expect(forwarding.sent == ["send"])
    }

    @Test(
        "Once the SDK accepts the send, it is reported as queued whatever happens next",
        arguments: ["session", "source deleted", "cancelled"])
    func acceptedSendStaysQueued(change: String) async throws {
        let forwarding = Forwarding()
        let review = try await forwarding.review()
        forwarding.destination.timeline.gate.arm()
        let pending = Task { try await forwarding.forward(review) }
        #expect(await eventually { forwarding.destination.timeline.gate.isWaiting })
        switch change {
        case "session": forwarding.f.apply(.session)
        case "source deleted": forwarding.service.threadMessages[0].isRedacted = true
        default: pending.cancel()
        }
        forwarding.destination.timeline.gate.release()
        #expect(try await pending.value.reviewID == review.id)
        #expect(forwarding.sent == ["send"])
    }
}

/// Media forwards reference the original upload: no download, and any change to it needs a fresh review.
@MainActor
struct ForwardMediaTests {
    enum Field: String, CaseIterable, CustomTestStringConvertible {
        case filename, caption, captionRemoved, formatting, source, infoRemoved, mime, size, thumbnailRemoved
        case thumbnailHeight, thumbnailWidth, thumbnailMime, thumbnailSize, thumbnailSource, thumbnailSourceRemoved
        case height, width, blurhash, animated
        var testDescription: String { rawValue }
        var imageOnly: Bool { [.height, .width, .blurhash, .animated].contains(self) }
    }

    private static func changing(_ type: MessageType, _ field: Field) throws -> MessageType {
        let replacement = try actionMediaSource(replacement: true)
        switch type {
        case .image(var value):
            switch field {
            case .filename: value.filename += "-changed"
            case .caption: value.caption = "Changed caption"
            case .captionRemoved: value.caption = nil
            case .formatting: value.formattedCaption = FormattedBody(format: .html, body: "<em>changed</em>")
            case .source: value.source = replacement
            case .infoRemoved: value.info = nil
            case .mime: value.info?.mimetype = "image/jpeg"
            case .size: value.info?.size = 999
            case .thumbnailRemoved: value.info?.thumbnailInfo = nil
            case .thumbnailHeight: value.info?.thumbnailInfo?.height = 999
            case .thumbnailWidth: value.info?.thumbnailInfo?.width = 999
            case .thumbnailMime: value.info?.thumbnailInfo?.mimetype = "image/jpeg"
            case .thumbnailSize: value.info?.thumbnailInfo?.size = 999
            case .thumbnailSource: value.info?.thumbnailSource = replacement
            case .thumbnailSourceRemoved: value.info?.thumbnailSource = nil
            case .height: value.info?.height = 999
            case .width: value.info?.width = 999
            case .blurhash: value.info?.blurhash = "changed"
            case .animated: value.info?.isAnimated = true
            }
            return .image(content: value)
        case .file(var value):
            switch field {
            case .filename: value.filename += "-changed"
            case .caption: value.caption = "Changed caption"
            case .captionRemoved: value.caption = nil
            case .formatting: value.formattedCaption = FormattedBody(format: .html, body: "<em>changed</em>")
            case .source: value.source = replacement
            case .infoRemoved: value.info = nil
            case .mime: value.info?.mimetype = "application/pdf"
            case .size: value.info?.size = 999
            case .thumbnailRemoved: value.info?.thumbnailInfo = nil
            case .thumbnailHeight: value.info?.thumbnailInfo?.height = 999
            case .thumbnailWidth: value.info?.thumbnailInfo?.width = 999
            case .thumbnailMime: value.info?.thumbnailInfo?.mimetype = "image/jpeg"
            case .thumbnailSize: value.info?.thumbnailInfo?.size = 999
            case .thumbnailSource: value.info?.thumbnailSource = replacement
            case .thumbnailSourceRemoved: value.info?.thumbnailSource = nil
            case .height, .width, .blurhash, .animated: break
            }
            return .file(content: value)
        default: return type
        }
    }
    private static func copied(_ type: MessageType) throws -> ForwardMessageContent {
        try ForwardMessageContent(MessageContent(msgType: type, body: "", isEdited: false, mentions: nil))
    }

    nonisolated static let copiedFields = [false, true].flatMap { file in
        Field.allCases.filter { !(file && $0.imageOnly) }.map { (file, $0) }
    }

    @Test("Any change to an image or file's copied fields counts as a different message", arguments: copiedFields)
    func everyFieldIsCompared(file: Bool, field: Field) throws {
        let original = captionedMedia(file: file, source: try actionMediaSource())
        #expect(try Self.copied(Self.changing(original, field)) != Self.copied(original))
    }

    // capability: message.forward
    @Test(
        "Own and incoming media forward with their caption and upload, without downloading anything",
        arguments: [false, true], [false, true])
    func forwardsMedia(file: Bool, own: Bool) async throws {
        let type = captionedMedia(file: file, source: try actionMediaSource())
        let forwarding = Forwarding(type, sender: own ? "@owner:example.org" : "@original:example.org")
        let review = try await forwarding.review()
        #expect(review.value == (try Self.copied(type)))
        #expect(review.message.mediaCaption == "Current caption")
        #expect(review.message.formattedBody?.contains("data-mx-spoiler") == true)
        #expect(review.value.mediaRevision == forwarding.service.forwardMessageSourceRevision(review.target)?.media)
        _ = try await forwarding.forward(review)
        #expect(forwarding.sent == ["send"])
        #expect(forwarding.f.client.mediaReads.all.isEmpty)
    }

    @Test("Unencrypted media is forwarded by reference, not downloaded and uploaded again")
    func plainMediaIsReferenced() async throws {
        let forwarding = Forwarding(
            captionedMedia(file: true, source: try MediaSource.fromUrl(url: "mxc://example.org/plain")))
        _ = try await forwarding.forward(try await forwarding.review())
        #expect(forwarding.sent == ["send"] && forwarding.f.client.mediaReads.all.isEmpty)
    }

    @Test(
        "A media change shown before sending invalidates the review and sends nothing",
        arguments: [false, true], [Field.source, .caption, .formatting, .thumbnailSource, .thumbnailWidth, .size])
    func shownChangeInvalidatesReview(file: Bool, field: Field) async throws {
        let original = captionedMedia(file: file, source: try actionMediaSource())
        let forwarding = Forwarding(original)
        let old = try await forwarding.review()
        let before = forwarding.service.forwardMessageSourceRevision(old.target)
        forwarding.publish(
            messageEvent("$root", type: try Self.changing(original, field), sender: "@original:example.org", own: false)
        )
        #expect(forwarding.service.forwardMessageSourceRevision(old.target) != before)
        do {
            _ = try await forwarding.forward(old)
            Issue.record("a changed attachment must not be sent")
        } catch let changed as ForwardMessageReviewChanged {
            #expect(changed.review.value != old.value && forwarding.sent.isEmpty)
            _ = try await forwarding.forward(changed.review)
            #expect(forwarding.sent == ["send"])
        }
    }

    @Test(
        "The SDK returning newer media than the timeline shows is refused until the timeline catches up",
        arguments: [false, true], [Field.source, .thumbnailWidth])
    func newerSDKMediaIsRefused(file: Bool, field: Field) async throws {
        let original = captionedMedia(file: file, source: try actionMediaSource())
        let forwarding = Forwarding(original)
        let target = try forwarding.target()
        forwarding.f.thread.event = messageEvent(
            "$root", type: try Self.changing(original, field), sender: "@original:example.org", own: false)
        await #expect(throws: (any Error).self) { try await forwarding.service.loadForwardMessage(target) }
    }

    @Test("A source replaced while the SDK read is in flight is refused before any destination setup")
    func replacementDuringReadIsRefused() async throws {
        let original = captionedMedia(file: false, source: try actionMediaSource())
        let forwarding = Forwarding(original)
        let target = try forwarding.target()
        forwarding.f.thread.readGate.arm()
        let reading = Task { try await forwarding.service.loadForwardMessage(target) }
        #expect(await eventually { forwarding.f.thread.readGate.isWaiting })
        forwarding.service.projectMediaCaptionForChecks(
            [
                FakeTimelineItem(
                    messageEvent(
                        "$root", type: try Self.changing(original, .source), sender: "@original:example.org", own: false
                    ))
            ],
            roomID: forwarding.f.roomID, inThread: true)
        forwarding.f.thread.readGate.release()
        await #expect(throws: (any Error).self) { try await reading.value }
        #expect(forwarding.destination.configurations.all.isEmpty && forwarding.sent.isEmpty)
    }

    @Test("A source replaced during destination setup returns a fresh review instead of sending")
    func replacementDuringSetupIsCaught() async throws {
        let original = captionedMedia(file: true, source: try actionMediaSource())
        let forwarding = Forwarding(original)
        let review = try await forwarding.review()
        forwarding.destination.setupGate.arm()
        let pending = Task { try await forwarding.forward(review) }
        #expect(await eventually { forwarding.destination.setupGate.isWaiting })
        forwarding.publish(
            messageEvent(
                "$root", type: try Self.changing(original, .source), sender: "@original:example.org", own: false))
        forwarding.destination.setupGate.release()
        await #expect(throws: ForwardMessageReviewChanged.self) { try await pending.value }
        #expect(forwarding.sent.isEmpty)
    }
}
