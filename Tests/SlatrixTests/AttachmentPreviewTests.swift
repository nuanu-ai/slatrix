import AppKit
import Foundation
import ImageIO
import MatrixRustSDK
import Testing
import UniformTypeIdentifiers

@testable import Slatrix

@MainActor
struct AttachmentPreviewTests {
    private let roomID = "!files:example.org"
    private let client: FakeClient
    private let service = MatrixService.scratch()

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

    @Test(
        "An inline SVG renders a rasterized still at its aspect ratio and falls back when the server cannot thumbnail"
    )
    func inlineSVGPreview() async throws {
        let svg = Data(
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 200 100">
              <rect width="200" height="100" fill="#2563eb"/>
            </svg>
            """.utf8)
        client.thumbnail = svg
        show(try imageEvent("$svg-direct", width: nil, height: nil, mime: "image/svg+xml"))
        let direct = try #require(service.messages.first)
        let image = try #require(await service.loadMediaImage(direct))
        #expect(image.width > 0 && image.height > 0)
        #expect(image.width == image.height * 2)

        // Unencrypted homeservers (e.g. Synapse) often fail thumbnailing SVG; fall back to the original content.
        client.thumbnailError = MatrixServiceError.request("Could not thumbnail SVG")
        client.stored = svg
        show(try imageEvent("$svg-fallback", width: nil, height: nil, mime: "image/svg+xml"))
        let fallback = try #require(service.messages.first)
        let fallbackImage = try #require(await service.loadMediaImage(fallback))
        #expect(fallbackImage.width == fallbackImage.height * 2)

        // Valid PDF spoofed as m.image must never be rasterized as an inline image or full image.
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 50)
        if let consumer = CGDataConsumer(data: pdfData as CFMutableData),
            let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(mediaBox)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        client.thumbnailError = nil
        client.thumbnail = pdfData as Data
        show(try imageEvent("$pdf-spoof", width: nil, height: nil, mime: "image/png"))
        let spoof = try #require(service.messages.first)
        #expect(await service.loadMediaImage(spoof) == nil)
        #expect(MediaImageDecoder.decodeFullImage(pdfData as Data) == nil)
    }

    @Test(
        "ViewBox-only SVGs decode cleanly, transparent dark-ink SVGs get a contrast matte, and EXIF JPEGs open upright"
    )
    func svgMatteAndExifOrientation() throws {
        let viewBoxOnly = Data(
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%" viewBox="0 0 240 120">
              <line x1="20" y1="60" x2="220" y2="60" stroke="#111111" stroke-width="16"/>
            </svg>
            """.utf8)
        let decoded = try #require(MediaImageDecoder.decodeStill(viewBoxOnly, maxPixels: 240))
        #expect(decoded.width == 240 && decoded.height == 120)
        // Transparent dark-ink SVG receives a light contrast matte in the corner so dark lines stay legible.
        let rep = NSBitmapImageRep(cgImage: decoded)
        let corner = try #require(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        #expect(corner.alphaComponent > 0.95 && corner.redComponent > 0.9)

        // Build a 120x60 JPEG tagged with EXIF orientation 6 (90° CW): full decode must produce upright 60x120.
        let rawRep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let cg = try #require(rawRep.cgImage)
        let jpeg = NSMutableData()
        let dest = try #require(
            CGImageDestinationCreateWithData(jpeg as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        let upright = try #require(MediaImageDecoder.decodeFullImage(jpeg as Data))
        #expect(Int(upright.size.width) == 60 && Int(upright.size.height) == 120)
    }

    @Test("Audio and voice events preserve duration, waveform, voice flag, caption, and actions")
    func audioAndVoiceMapping() async throws {
        let source = try encryptedSource(url: "mxc://example.org/voice")
        let audio = AudioMessageContent(
            filename: "voice.ogg", caption: "Quick voice note",
            formattedCaption: FormattedBody(format: .html, body: "<em>Quick voice note</em>"),
            source: source,
            info: AudioInfo(duration: 12.5, size: 48_000, mimetype: "audio/ogg"),
            audio: UnstableAudioDetailsContent(duration: 12.5, waveform: [120, 480, 920, 310]),
            voice: UnstableVoiceContent())
        let event = EventTimelineItem(
            isRemote: true, eventOrTransactionId: .eventId(eventId: "$voice"), sender: "@owner:example.org",
            senderProfile: .unavailable, forwarder: nil, forwarderProfile: nil, isOwn: true, isEditable: true,
            content: .msgLike(
                content: MsgLikeContent(
                    kind: .message(
                        content: MessageContent(
                            msgType: .audio(content: audio), body: "Quick voice note", isEdited: false, mentions: nil)),
                    inReplyTo: nil, threadRoot: nil, threadSummary: nil)),
            reactions: [], eventTypeRaw: "m.room.message", timestamp: 2_000, localSendState: nil, editSendState: nil,
            redactionSendState: nil, localCreatedAt: nil, readReceipts: [:], origin: nil, canBeRepliedTo: true,
            lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
        show(event)
        let message = try #require(service.messages.first)
        #expect(message.kind == "m.audio")
        #expect(message.mediaCaption == "Quick voice note")
        #expect(message.formattedBody == "<em>Quick voice note</em>")
        #expect(message.attachment?.duration == 12.5)
        #expect(message.attachment?.waveform == [120, 480, 920, 310])
        #expect(message.attachment?.isVoice == true)
        #expect(message.supportsCaptionEditing)
        #expect(ForwardMessageContent.supports(message))
    }

    @Test("Video events preserve caption, formatted caption, caption editing and forwarding")
    func videoCaptionAndForwarding() throws {
        let source = try encryptedSource(url: "mxc://example.org/clip")
        let video = VideoMessageContent(
            filename: "demo.mp4", caption: "Walkthrough",
            formattedCaption: FormattedBody(format: .html, body: "<b>Walkthrough</b>"),
            source: source,
            info: VideoInfo(
                duration: 42, height: 720, width: 1_280, mimetype: "video/mp4", size: 2_000,
                thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil))
        let msgContent = MessageContent(
            msgType: .video(content: video), body: "Walkthrough", isEdited: false, mentions: nil)
        let event = EventTimelineItem(
            isRemote: true, eventOrTransactionId: .eventId(eventId: "$vidcap"), sender: "@owner:example.org",
            senderProfile: .unavailable, forwarder: nil, forwarderProfile: nil, isOwn: true, isEditable: true,
            content: .msgLike(
                content: MsgLikeContent(
                    kind: .message(content: msgContent),
                    inReplyTo: nil, threadRoot: nil, threadSummary: nil)),
            reactions: [], eventTypeRaw: "m.room.message", timestamp: 2_100, localSendState: nil, editSendState: nil,
            redactionSendState: nil, localCreatedAt: nil, readReceipts: [:], origin: nil, canBeRepliedTo: true,
            lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
        show(event)
        let message = try #require(service.messages.first)
        #expect(message.mediaCaption == "Walkthrough")
        #expect(message.formattedBody == "<b>Walkthrough</b>")
        #expect(message.supportsCaptionEditing)
        #expect(ForwardMessageContent.supports(message))
        let captionContent = try MediaCaptionContent(msgContent)
        #expect(captionContent.caption == "Walkthrough")
        let forwardContent = try ForwardMessageContent(msgContent)
        #expect(forwardContent.mediaRevision != nil)
    }

    @Test("Stickers map to inline media attachments with source and load their image without duplicating body text")
    func stickerMapsToInlineMedia() async throws {
        client.thumbnail = try pngData()
        let source = try encryptedSource(url: "mxc://example.org/sticker")
        let info = ImageInfo(
            height: 128, width: 128, mimetype: "image/png", size: 4_000,
            thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: false)
        let event = EventTimelineItem(
            isRemote: true, eventOrTransactionId: .eventId(eventId: "$sticker"), sender: "@owner:example.org",
            senderProfile: .unavailable, forwarder: nil, forwarderProfile: nil, isOwn: false, isEditable: false,
            content: .msgLike(
                content: MsgLikeContent(
                    kind: .sticker(body: "Happy wave", info: info, source: source),
                    inReplyTo: nil, threadRoot: nil, threadSummary: nil)),
            reactions: [], eventTypeRaw: "m.sticker", timestamp: 2_200, localSendState: nil, editSendState: nil,
            redactionSendState: nil, localCreatedAt: nil, readReceipts: [:], origin: nil, canBeRepliedTo: true,
            lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
        show(event)
        let message = try #require(service.messages.first)
        #expect(message.kind == "m.sticker")
        #expect(message.attachment?.name == "Happy wave")
        #expect(message.attachment?.width == 128 && message.attachment?.height == 128)
        #expect(message.isViewerMedia)
        #expect(!message.showsMessageBody)
        let image = try #require(await service.loadMediaImage(message))
        #expect(image.width > 0 && image.height > 0)
    }

    @Test("Upload MIME detection resolves webm, mkv, ogg, opus and flac even when UTType has no preferred MIME")
    func uploadMimeDetection() {
        func resolve(_ name: String) -> String {
            MatrixMapping.resolvedUploadMIMEType(for: URL(fileURLWithPath: "/tmp/\(name)"), contentType: nil)
        }
        #expect(resolve("demo.webm") == "video/webm")
        #expect(resolve("demo.mkv") == "video/x-matroska")
        #expect(resolve("voice.ogg") == "audio/ogg")
        #expect(resolve("voice.opus") == "audio/ogg")
        #expect(resolve("track.flac") == "audio/flac")
    }
}
