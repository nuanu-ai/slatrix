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

    // capability: message.thread-summary
    @Test("A thread root carries its reply count and who replied last, and when")
    func threadSummary() throws {
        final class Summary: ThreadSummary, @unchecked Sendable {
            override func numReplies() -> UInt64 { 4 }
            override func latestEvent() -> EmbeddedEventDetails {
                .ready(
                    content: .msgLike(
                        content: MsgLikeContent(kind: .redacted, inReplyTo: nil, threadRoot: nil, threadSummary: nil)),
                    sender: "@julia:example.org",
                    senderProfile: .ready(
                        displayName: "Julia", displayNameAmbiguous: false, avatarUrl: "mxc://example.org/julia",
                        status: nil, call: nil),
                    timestamp: 1_800_000_000_000, eventOrTransactionId: .eventId(eventId: "$last"))
            }
        }
        var item = event(.eventId(eventId: "$root"), remote: true, kind: text)
        item.content = .msgLike(
            content: MsgLikeContent(
                kind: text, inReplyTo: nil, threadRoot: nil, threadSummary: Summary(noHandle: .init())))
        let message = try #require(
            MatrixMapping.message(item, roomID: "!r:example.org", ownUserID: "@me:example.org"))
        #expect(message.replyCount == 4)
        #expect(
            message.lastReply
                == ThreadReply(
                    senderID: "@julia:example.org", senderName: "Julia", avatarURL: "mxc://example.org/julia",
                    timestamp: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    // capability: message.image
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

    private func mapped(_ type: MessageType, body: String) throws -> MessageAttachment {
        let kind = MsgLikeKind.message(
            content: MessageContent(msgType: type, body: body, isEdited: false, mentions: nil))
        let message = try #require(
            MatrixMapping.message(
                event(.eventId(eventId: "$media"), remote: true, kind: kind), roomID: "!r:example.org", ownUserID: nil))
        return try #require(message.attachment)
    }

    @Test(
        "A GIF animates inline and a still image does not, whether or not the sender said so",
        arguments: [
            ("image/gif", nil, true), ("image/gif", false, false), ("image/png", true, true),
            ("image/jpeg", nil, false),
        ] as [(String, Bool?, Bool)])
    func animatedImage(mime: String, declared: Bool?, animates: Bool) throws {
        let image = ImageMessageContent(
            filename: "party", caption: nil, formattedCaption: nil, source: try encryptedSource(),
            info: ImageInfo(
                height: 200, width: 200, mimetype: mime, size: 1_000, thumbnailInfo: nil, thumbnailSource: nil,
                blurhash: nil, isAnimated: declared))
        #expect(try mapped(.image(content: image), body: "party").animated == animates)
    }

    // capability: message.video
    @Test("A video carries its duration and size for its poster")
    func videoDuration() throws {
        let video = VideoMessageContent(
            filename: "demo.mp4", caption: nil, formattedCaption: nil, source: try encryptedSource(),
            info: VideoInfo(
                duration: 83, height: 720, width: 1_280, mimetype: "video/mp4", size: 4_000_000, thumbnailInfo: nil,
                thumbnailSource: nil, blurhash: nil))
        let attachment = try mapped(.video(content: video), body: "demo.mp4")
        #expect(attachment.duration == 83 && attachment.width == 1_280 && attachment.height == 720)
    }

    struct FileKindCase: Decodable, CustomTestStringConvertible {
        var name: String
        var mime: String?
        var kind: String
        var label: String
        var testDescription: String { name }
    }

    struct FileKindSpec: Decodable { var cases: [FileKindCase] }

    // capability: message.file
    @Test(
        "A file's kind and type label follow spec/file-kind.json",
        arguments: try SharedSpec.decode("spec/file-kind.json", as: FileKindSpec.self).cases)
    func fileKind(spec: FileKindCase) throws {
        let file = FileMessageContent(
            filename: spec.name, caption: nil, formattedCaption: nil, source: try encryptedSource(),
            info: FileInfo(mimetype: spec.mime, size: 2_000_000, thumbnailInfo: nil, thumbnailSource: nil))
        let attachment = try mapped(.file(content: file), body: spec.name)
        #expect(String(describing: attachment.fileKind) == spec.kind)
        #expect(attachment.typeLabel == spec.label)
    }
}
