import Foundation
import MatrixRustSDK

// The SDK's current typed content, not the original raw event: the latter may
// precede a media replacement. Copying this value retains source/info/filename.
enum MediaCaptionContent {
    case image(ImageMessageContent)
    case file(FileMessageContent)

    init(_ content: MessageContent) throws {
        switch content.msgType {
        case .image(let value): self = .image(value)
        case .file(let value): self = .file(value)
        default: throw MediaCaptionError.unsupported
        }
    }
    var caption: String? {
        switch self {
        case .image(let value): value.caption
        case .file(let value): value.caption
        }
    }
    var formattedCaption: FormattedBody? {
        switch self {
        case .image(let value): value.formattedCaption
        case .file(let value): value.formattedCaption
        }
    }
    var source: MediaSource {
        switch self {
        case .image(let value): value.source
        case .file(let value): value.source
        }
    }
    var filename: String {
        switch self {
        case .image(let value): value.filename
        case .file(let value): value.filename
        }
    }
    func replacingCaption(_ caption: String?) -> MessageContent {
        let type: MessageType
        switch self {
        case .image(var value):
            value.caption = caption
            value.formattedCaption = nil
            type = .image(content: value)
        case .file(var value):
            value.caption = caption
            value.formattedCaption = nil
            type = .file(content: value)
        }
        return MessageContent(msgType: type, body: caption ?? filename, isEdited: false, mentions: nil)
    }
    func payload(caption: String?) throws -> RoomMessageEventContentWithoutRelation {
        try contentWithoutRelationFromMessage(message: replacingCaption(caption))
            .withMentions(mentions: Mentions(userIds: [], room: false))
    }
}
struct MediaCaptionRevision: Hashable {
    let attachment: MessageAttachment
    let source: String
    let kind: String
    let caption: String?
    let formattedCaption: FormattedBody?
}
struct MediaCaptionSnapshot: Identifiable {
    let id = UUID()
    let target: MessageActionTarget
    let message: ChatMessage
    let media: MediaCaptionContent
    let revision: MediaCaptionRevision
    var caption: String? { media.caption }
    var filename: String { media.filename }
}
struct MediaCaptionSavedResult {
    let snapshotID: UUID
    let queued: Bool
}
struct MediaCaptionReviewChanged: LocalizedError {
    let snapshot: MediaCaptionSnapshot
    var errorDescription: String? { "The caption changed. Check it, then save." }
}
enum MediaCaptionError: LocalizedError {
    case unsupported, unconfirmed, busy, sourceUpdating
    var errorDescription: String? {
        switch self {
        case .unsupported: "You can’t edit this caption."
        case .unconfirmed: "Wait for the pending edit or deletion to finish before editing this caption."
        case .busy: "This caption is already being saved. Wait for the current request to finish."
        case .sourceUpdating: "This attachment is updating. Reload the message before editing its caption."
        }
    }
}
