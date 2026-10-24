import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

struct TimelineMappingTests {
    private func event(_ id: EventOrTransactionId, remote: Bool, kind: MsgLikeKind) -> EventTimelineItem {
        EventTimelineItem(
            isRemote: remote, eventOrTransactionId: id, sender: "@me:example.org", senderProfile: .unavailable,
            forwarder: nil, forwarderProfile: nil, isOwn: true, isEditable: true,
            content: .msgLike(content: MsgLikeContent(kind: kind, inReplyTo: nil, threadRoot: nil, threadSummary: nil)),
            reactions: [], eventTypeRaw: "m.room.message", timestamp: 1_000,
            localSendState: remote ? nil : .notSentYet(progress: nil), editSendState: nil, redactionSendState: nil,
            localCreatedAt: nil, readReceipts: [:], origin: nil, canBeRepliedTo: true,
            lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
    }
    private let text = MsgLikeKind.message(
        content: MessageContent(
            msgType: .text(content: TextMessageContent(body: "Hello", formatted: nil)), body: "Hello",
            isEdited: false, mentions: nil))

    @Test("A sent message keeps its identity when the server's event replaces the local echo")
    func localEchoKeepsIdentity() throws {
        let echo = try #require(
            MatrixMapping.message(
                event(.transactionId(transactionId: "txn"), remote: false, kind: text), roomID: "!r:example.org",
                ownUserID: "@me:example.org", uniqueID: "item-7"))
        let sent = try #require(
            MatrixMapping.message(
                event(.eventId(eventId: "$sent"), remote: true, kind: text), roomID: "!r:example.org",
                ownUserID: "@me:example.org", uniqueID: "item-7"))
        #expect(echo.id == sent.id)
        #expect(echo.eventID == "txn" && echo.sendState == "sending")
        #expect(sent.eventID == "$sent" && sent.sendState == "sent")
    }

    @Test("A message from outside a live timeline is identified by its event")
    func eventIdentity() throws {
        let message = try #require(
            MatrixMapping.message(
                event(.eventId(eventId: "$found"), remote: true, kind: text), roomID: "!r:example.org",
                ownUserID: nil))
        #expect(message.id == "$found" && message.eventID == "$found")
    }

    @Test("An image carries its pixel size, so its box is reserved before the thumbnail loads")
    func imageDimensions() throws {
        let image = ImageMessageContent(
            filename: "beach.jpg", caption: nil, formattedCaption: nil, source: try encryptedSource(),
            info: ImageInfo(
                height: 900, width: 1_600, mimetype: "image/jpeg", size: 1_000, thumbnailInfo: nil,
                thumbnailSource: nil, blurhash: nil, isAnimated: nil))
        let kind = MsgLikeKind.message(
            content: MessageContent(msgType: .image(content: image), body: "beach.jpg", isEdited: false, mentions: nil))
        let message = try #require(
            MatrixMapping.message(
                event(.eventId(eventId: "$image"), remote: true, kind: kind), roomID: "!r:example.org", ownUserID: nil))
        #expect(message.attachment?.width == 1_600 && message.attachment?.height == 900)
    }
}
