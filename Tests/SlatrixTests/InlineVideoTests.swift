import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// A video in a conversation over the fake client, whose download isn't a movie.
@MainActor
private func videoConversation() throws -> MatrixService {
    let roomID = "!videos:example.org"
    let client = FakeClient(rooms: [FakeRoom(roomInfo(id: roomID))])
    client.file = Data("not a movie".utf8)
    let service = MatrixService()
    service.configureMessageActionsForChecks(
        client: client, main: nil, thread: nil, rootID: nil, sessionID: UUID(), selectionID: UUID(), threadID: UUID())
    service.selectedRoomID = roomID
    service.projectMediaCaptionForChecks(
        [FakeTimelineItem(videoEvent("$video", source: try encryptedSource(url: "mxc://example.org/video")))],
        roomID: roomID, inThread: false)
    return service
}

/// The one video a window plays in its timeline, when it can't.
@MainActor
struct InlineVideoTests {
    private let video = InlineVideo()
    private let timeline = NSObject()

    @Test("A video whose file can't be had goes back to its poster")
    func unavailable() async throws {
        let service = try videoConversation()
        var gone = try #require(service.messages.first)
        gone.id = "$gone"
        gone.timelineEventID = nil
        video.play(gone, matrix: service, from: timeline)
        #expect(video.eventID == "$gone")
        #expect(await eventually { video.eventID == nil })
        #expect(video.player == nil)
        // No error, which would mean the file was had and failed to play.
        #expect(service.errorMessage == nil)
    }

    @Test("A video that won't play goes back to its poster and says so")
    func unplayable() async throws {
        let service = try videoConversation()
        video.play(try #require(service.messages.first), matrix: service, from: timeline)
        // The player for a bad file can fail before a poll sees it, so only where it ends up is checked.
        #expect(await eventually { video.eventID == nil && service.errorMessage != nil })
        #expect(video.player == nil)
    }
}
