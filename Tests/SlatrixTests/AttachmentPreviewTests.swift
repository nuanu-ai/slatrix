import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

@MainActor
struct AttachmentPreviewTests {
    private let roomID = "!files:example.org"
    private let client: FakeClient
    private let service = MatrixService()

    init() {
        client = FakeClient(rooms: [FakeRoom(roomInfo(id: roomID))])
        service.configureMessageActionsForChecks(
            client: client, main: nil, thread: nil, rootID: nil, sessionID: UUID(), selectionID: UUID(),
            threadID: UUID())
        service.selectedRoomID = roomID
    }
    private func show(_ event: EventTimelineItem) {
        service.projectMediaCaptionForChecks([FakeTimelineItem(event)], roomID: roomID, inThread: false)
    }

    @Test("Your own image shows while it sends, from the copy being sent, and stays as its upload finishes")
    func sendingImage() async throws {
        // Only the copy being sent is a picture; the server's thumbnail is empty.
        client.stored = try pngData()
        func sending(_ url: String) throws {
            show(try imageEvent("photo-transaction", width: 160, height: 90, url: url, sending: true))
        }
        try sending("mxc://send-queue.localhost/photo")
        let queued = try #require(service.messages.first)
        let image = try #require(await service.loadMediaImage(queued))
        try sending("mxc://example.org/photo")
        #expect(service.cachedMediaImage(try #require(service.messages.first)) === image)
    }

    // capability: message.file
    @Test("Previewing an attachment again reuses the downloaded file")
    func reusesDownload() async throws {
        show(fileEvent("$file", source: try encryptedSource()))
        let message = try #require(service.messages.first)
        let first = try await service.prepareAttachmentPreview(message)
        let second = try await service.prepareAttachmentPreview(message)
        #expect(first.url == second.url && client.downloads == 1)
    }

    @Test("A video without a poster gets a plain box instead of fetching its own file as a thumbnail")
    func videoWithoutPoster() async throws {
        client.thumbnail = Data([1, 2, 3])
        let video = VideoMessageContent(
            filename: "demo.mp4", caption: nil, formattedCaption: nil, source: try encryptedSource(),
            info: VideoInfo(
                duration: 12, height: 720, width: 1_280, mimetype: "video/mp4", size: 1_000, thumbnailInfo: nil,
                thumbnailSource: nil, blurhash: nil))
        let event = EventTimelineItem(
            isRemote: true, eventOrTransactionId: .eventId(eventId: "$video"), sender: "@owner:example.org",
            senderProfile: .unavailable, forwarder: nil, forwarderProfile: nil, isOwn: true, isEditable: true,
            content: .msgLike(
                content: MsgLikeContent(
                    kind: .message(
                        content: MessageContent(
                            msgType: .video(content: video), body: "demo.mp4", isEdited: false, mentions: nil)),
                    inReplyTo: nil, threadRoot: nil, threadSummary: nil)),
            reactions: [], eventTypeRaw: "m.room.message", timestamp: 1_000, localSendState: nil, editSendState: nil,
            redactionSendState: nil, localCreatedAt: nil, readReceipts: [:], origin: nil, canBeRepliedTo: true,
            lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
        show(event)
        let message = try #require(service.messages.first)
        await #expect(throws: MatrixServiceError.self) { _ = try await self.service.thumbnailData(message) }
    }

    @Test(
        "A preview ends when its message is deleted or its file is replaced, even under the same URL",
        arguments: [nil, "AQAAAAAAAAAAAAAAAAAAAA"])
    func endsWhenMessageChanges(replacementKey: String?) async throws {
        show(fileEvent("$file", source: try encryptedSource()))
        let message = try #require(service.messages.first)
        let preview = try await service.prepareAttachmentPreview(message)
        #expect(preview.isCurrent)
        show(fileEvent("$file", source: try replacementKey.map { try encryptedSource(key: $0) }))
        #expect(!preview.isCurrent)
        if replacementKey != nil {
            let current = try #require(service.messages.first)
            _ = try await service.prepareAttachmentPreview(current)
            #expect(client.downloads == 2)
        }
    }
}
