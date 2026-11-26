import CoreMedia
import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

@MainActor
private func audioConversation() throws -> MatrixService {
    let roomID = "!audio:example.org"
    let client = FakeClient(rooms: [FakeRoom(roomInfo(id: roomID))])
    client.file = Data("not audio".utf8)
    let service = MatrixService.scratch()
    service.configureMessageActionsForChecks(
        client: client, main: nil, thread: nil, rootID: nil, sessionID: UUID(), selectionID: UUID(), threadID: UUID())
    service.selectedRoomID = roomID
    let audio = AudioMessageContent(
        filename: "voice.ogg", caption: nil, formattedCaption: nil,
        source: try encryptedSource(url: "mxc://example.org/voice"),
        info: AudioInfo(duration: 8.0, size: 12_000, mimetype: "audio/ogg"),
        audio: UnstableAudioDetailsContent(duration: 8.0, waveform: [100, 500, 900]),
        voice: UnstableVoiceContent())
    let event = EventTimelineItem(
        isRemote: true, eventOrTransactionId: .eventId(eventId: "$voice"), sender: "@owner:example.org",
        senderProfile: .unavailable, forwarder: nil, forwarderProfile: nil, isOwn: true, isEditable: false,
        content: .msgLike(
            content: MsgLikeContent(
                kind: .message(
                    content: MessageContent(
                        msgType: .audio(content: audio), body: "voice.ogg", isEdited: false, mentions: nil)),
                inReplyTo: nil, threadRoot: nil, threadSummary: nil)),
        reactions: [], eventTypeRaw: "m.room.message", timestamp: 1_000, localSendState: nil, editSendState: nil,
        redactionSendState: nil, localCreatedAt: nil, readReceipts: [:], origin: nil, canBeRepliedTo: true,
        lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
    service.projectMediaCaptionForChecks([FakeTimelineItem(event)], roomID: roomID, inThread: false)
    return service
}

@MainActor
struct InlineAudioTests {
    private let audio = InlineAudio()
    private let timeline = NSObject()

    @Test("An audio clip that fails to play stops cleanly and records an inline error for that event")
    func unplayableAudioRecordsError() async throws {
        let service = try audioConversation()
        let message = try #require(service.messages.first)
        audio.toggle(message, matrix: service, from: timeline)
        #expect(await eventually { audio.eventID == nil && audio.errorEventID == "$voice" })
        #expect(audio.errorMessage != nil)
        #expect(!audio.isPlaying)
    }

    @Test("Closing MediaViewer clears carried video timestamp and pauses sibling inline audio")
    func viewerCloseClearsCarriedAndStopsViewerAudio() throws {
        let viewer = MediaViewerState()
        let videoMsg = ChatMessage(
            id: "$v", roomID: "!r:example.org", senderID: "@a:example.org", senderName: "A", body: "v.mp4",
            timestamp: Date(timeIntervalSince1970: 0), kind: "m.video",
            attachment: MessageAttachment(name: "v.mp4", url: "mxc://example.org/v", mimeType: "video/mp4"))
        viewer.open(videoMsg, surface: .conversation)
        viewer.close()
        #expect(viewer.videoStart(videoMsg) == .zero)
    }
}
