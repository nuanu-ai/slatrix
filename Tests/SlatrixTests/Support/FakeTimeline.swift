import Foundation
import MatrixRustSDK

/// Like the SDK, its unique ID differs from the event ID and survives a local echo becoming remote.
final class FakeTimelineItem: TimelineItem, @unchecked Sendable {
    private let event: EventTimelineItem?
    private let virtual: VirtualTimelineItem?
    private let unique: String
    init(_ event: EventTimelineItem? = nil, virtual: VirtualTimelineItem? = nil, uniqueID: String? = nil) {
        self.event = event
        self.virtual = virtual
        unique = uniqueID ?? "item-" + UUID().uuidString
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func asEvent() -> EventTimelineItem? { event }
    override func asVirtual() -> VirtualTimelineItem? { virtual }
    override func uniqueId() -> TimelineUniqueId { TimelineUniqueId(id: unique) }
}

/// An encrypted file source; `key` stands in for the per-upload encryption key.
func encryptedSource(url: String = "mxc://example.org/media", key: String = "AAAAAAAAAAAAAAAAAAAAAA") throws
    -> MediaSource
{
    try MediaSource.fromJson(
        json: """
            {"file":{"url":"\(url)","key":{"kty":"oct","key_ops":["encrypt","decrypt"],"alg":"A256CTR","k":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","ext":true},"iv":"\(key)","hashes":{"sha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"},"v":"v2"}}
            """)
}

func fileEvent(_ id: String, source: MediaSource?, sender: String = "@owner:example.org") -> EventTimelineItem {
    let kind: MsgLikeKind
    if let source {
        let file = FileMessageContent(
            filename: "report.txt", caption: nil, formattedCaption: nil, source: source,
            info: FileInfo(mimetype: "text/plain", size: 72, thumbnailInfo: nil, thumbnailSource: nil))
        kind = .message(
            content: MessageContent(msgType: .file(content: file), body: "report.txt", isEdited: false, mentions: nil))
    } else {
        kind = .redacted
    }
    return EventTimelineItem(
        isRemote: true, eventOrTransactionId: .eventId(eventId: id), sender: sender, senderProfile: .unavailable,
        forwarder: nil, forwarderProfile: nil, isOwn: true, isEditable: true,
        content: .msgLike(content: MsgLikeContent(kind: kind, inReplyTo: nil, threadRoot: nil, threadSummary: nil)),
        reactions: [], eventTypeRaw: "m.room.message", timestamp: 1_000, localSendState: nil, editSendState: nil,
        redactionSendState: nil, localCreatedAt: nil, readReceipts: [:], origin: nil, canBeRepliedTo: true,
        lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
}

/// A remote image, or with `sending` the reader's own local echo of it, whose `id` is then its transaction ID.
func imageEvent(
    _ id: String, width: UInt64?, height: UInt64?, mime: String = "image/png", url: String? = nil,
    sending: Bool = false
) throws -> EventTimelineItem {
    let image = ImageMessageContent(
        filename: "photo.png", caption: nil, formattedCaption: nil,
        source: try MediaSource.fromUrl(url: url ?? "mxc://example.org/\(id.dropFirst())"),
        info: ImageInfo(
            height: height, width: width, mimetype: mime, size: 1_000, thumbnailInfo: nil, thumbnailSource: nil,
            blurhash: nil, isAnimated: nil))
    return EventTimelineItem(
        isRemote: !sending, eventOrTransactionId: sending ? .transactionId(transactionId: id) : .eventId(eventId: id),
        sender: "@alice:example.org", senderProfile: .unavailable, forwarder: nil, forwarderProfile: nil,
        isOwn: sending, isEditable: sending,
        content: .msgLike(
            content: MsgLikeContent(
                kind: .message(
                    content: MessageContent(
                        msgType: .image(content: image), body: "photo.png", isEdited: false, mentions: nil)),
                inReplyTo: nil, threadRoot: nil, threadSummary: nil)),
        reactions: [], eventTypeRaw: "m.room.message", timestamp: 1_000,
        localSendState: sending ? .notSentYet(progress: nil) : nil, editSendState: nil,
        redactionSendState: nil, localCreatedAt: nil, readReceipts: [:], origin: nil, canBeRepliedTo: true,
        lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
}

func textEvent(
    _ id: String, body: String, sender: String = "@alice:example.org", edited: Bool = false, redacted: Bool = false
) -> EventTimelineItem {
    let kind: MsgLikeKind =
        redacted
        ? .redacted
        : .message(
            content: MessageContent(
                msgType: .text(content: TextMessageContent(body: body, formatted: nil)), body: body, isEdited: edited,
                mentions: nil))
    return EventTimelineItem(
        isRemote: true, eventOrTransactionId: .eventId(eventId: id), sender: sender, senderProfile: .unavailable,
        forwarder: nil, forwarderProfile: nil, isOwn: false, isEditable: false,
        content: .msgLike(content: MsgLikeContent(kind: kind, inReplyTo: nil, threadRoot: nil, threadSummary: nil)),
        reactions: [], eventTypeRaw: "m.room.message", timestamp: 1_000, localSendState: nil, editSendState: nil,
        redactionSendState: nil, localCreatedAt: nil, readReceipts: [:], origin: nil, canBeRepliedTo: true,
        lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
}
