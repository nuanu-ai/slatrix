import CryptoKit
import Foundation
import MatrixRustSDK

// Compare only the typed fields that will actually be copied. Reactions,
// profile changes, old reply relations and old mentions do not change a copy.
enum ForwardMessageContent: Equatable {
    case text(TextMessageContent)
    case notice(NoticeMessageContent)
    case emote(EmoteMessageContent)
    case image(ImageMessageContent)
    case file(FileMessageContent)

    init(_ content: MessageContent) throws {
        switch content.msgType {
        case .text(let value): self = .text(value)
        case .notice(let value): self = .notice(value)
        case .emote(let value): self = .emote(value)
        case .image(let value): self = .image(value)
        case .file(let value): self = .file(value)
        default: throw ForwardMessageError.unsupported
        }
    }
    var mediaRevision: ForwardMediaRevision? {
        switch self {
        case .image(let value): ForwardMediaRevision(value)
        case .file(let value): ForwardMediaRevision(value)
        default: nil
        }
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)): a == b
        case (.notice(let a), .notice(let b)): a == b
        case (.emote(let a), .emote(let b)): a == b
        case (.image, .image), (.file, .file): lhs.mediaRevision == rhs.mediaRevision
        default: false
        }
    }
    static func supports(_ message: ChatMessage) -> Bool {
        ["m.text", "m.notice", "m.emote", "m.image", "m.file"].contains(message.kind) && !message.isRedacted
            && message.sendState == "sent" && message.eventID.hasPrefix("$")
    }
}
// Complete identity for the media fields copied by the official helper. No
// parsing of encryption JSON: opaque source identities are compared by digest.
struct ForwardMediaRevision: Hashable {
    struct Info: Hashable {
        var height: UInt64? = nil
        var width: UInt64? = nil
        let mimetype: String?
        let size: UInt64?
        let thumbnail: ThumbnailInfo?
        let thumbnailSource: Data?
        var blurhash: String? = nil
        var isAnimated: Bool? = nil
    }
    let filename: String
    let caption: String?
    let formattedCaption: FormattedBody?
    let source: Data
    let info: Info?

    private static func fingerprint(_ source: MediaSource) -> Data {
        Data(SHA256.hash(data: Data(source.toJson().utf8)))
    }
    init(_ value: ImageMessageContent) {
        filename = value.filename
        caption = value.caption
        formattedCaption = value.formattedCaption
        source = Self.fingerprint(value.source)
        info = value.info.map {
            Info(
                height: $0.height, width: $0.width, mimetype: $0.mimetype, size: $0.size,
                thumbnail: $0.thumbnailInfo, thumbnailSource: $0.thumbnailSource.map(Self.fingerprint),
                blurhash: $0.blurhash, isAnimated: $0.isAnimated)
        }
    }
    init(_ value: FileMessageContent) {
        filename = value.filename
        caption = value.caption
        formattedCaption = value.formattedCaption
        source = Self.fingerprint(value.source)
        info = value.info.map {
            Info(
                mimetype: $0.mimetype, size: $0.size, thumbnail: $0.thumbnailInfo,
                thumbnailSource: $0.thumbnailSource.map(Self.fingerprint))
        }
    }
}
struct ForwardMessageReview: Identifiable {
    let id = UUID()
    let target: MessageActionTarget
    let message: ChatMessage
    let value: ForwardMessageContent
    let content: MessageContent

    func payload() throws -> RoomMessageEventContentWithoutRelation {
        // An explicit empty m.mentions suppresses legacy body/display-name
        // mention inference; custom keyword notification rules remain separate.
        try contentWithoutRelationFromMessage(message: content)
            .withMentions(mentions: Mentions(userIds: [], room: false))
    }
}
struct ForwardMessageSourceRevision: Hashable {
    let kind: String
    let body: String
    let formattedBody: String?
    let redacted: Bool
    let sendState: String
    var media: ForwardMediaRevision? = nil
}
struct ForwardMessageQueuedResult {
    let reviewID: UUID
    let destinationRoomID: String
}
struct ForwardMessageReviewChanged: LocalizedError {
    let review: ForwardMessageReview
    var errorDescription: String? { "The message changed. Check it, then forward." }
}
enum ForwardMessageError: LocalizedError {
    case unsupported, unconfirmed, unavailableDestination, unencryptedDestination, forbidden, busy, sourceUpdating
    var errorDescription: String? {
        switch self {
        case .unsupported: "This message can’t be forwarded."
        case .unconfirmed: "Wait for this message’s pending edit or deletion to finish before forwarding."
        case .unavailableDestination: "Choose a conversation you’ve joined."
        case .unencryptedDestination:
            "Choose an encrypted conversation for a message from an encrypted one."
        case .forbidden: "You can’t post in that conversation. Choose another."
        case .sourceUpdating: "This attachment is updating. Reload the message before forwarding it."
        case .busy: "This message is already being forwarded."
        }
    }
}
