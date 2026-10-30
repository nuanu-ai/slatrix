import AVFoundation
import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// Shows two playable videos in a conversation over the fake client.
@MainActor
func videoConversation() async throws -> (MatrixService, TemporaryDirectory) {
    let roomID = "!videos:example.org"
    let folder = try TemporaryDirectory()
    let client = FakeClient(rooms: [FakeRoom(roomInfo(id: roomID))])
    client.file = try Data(
        contentsOf: try await folder.video("clip.mov", width: 32, height: 18, rotation: 0, seconds: 2))
    let service = MatrixService()
    service.configureMessageActionsForChecks(
        client: client, main: nil, thread: nil, rootID: nil, sessionID: UUID(), selectionID: UUID(), threadID: UUID())
    service.selectedRoomID = roomID
    service.projectMediaCaptionForChecks(
        [
            FakeTimelineItem(videoEvent("$first", source: try encryptedSource(url: "mxc://example.org/first"))),
            FakeTimelineItem(videoEvent("$second", source: try encryptedSource(url: "mxc://example.org/second"))),
        ], roomID: roomID, inThread: false)
    return (service, folder)
}

/// The one video a window plays in its timeline.
@MainActor
struct InlineVideoTests {
    private let video = InlineVideo()
    private let timeline = NSObject()

    // capability: message.video
    @Test("A video plays in place once its file is down, and starting another stops the first")
    func oneAtATime() async throws {
        let (service, _) = try await videoConversation()
        let first = try #require(service.messages.first { $0.eventID == "$first" })
        let second = try #require(service.messages.first { $0.eventID == "$second" })
        video.play(first, matrix: service, from: timeline)
        #expect(video.eventID == "$first")
        #expect(await eventually { (video.player?.rate ?? 0) > 0 })
        let playing = try #require(video.player)

        video.play(second, matrix: service, from: timeline)
        #expect(playing.rate == 0)
        #expect(await eventually { video.eventID == "$second" && (video.player?.rate ?? 0) > 0 })
    }

    @Test("A video whose file can't be had goes back to its poster")
    func unavailable() async throws {
        let (service, _) = try await videoConversation()
        var gone = try #require(service.messages.first)
        gone.id = "$gone"
        gone.timelineEventID = nil
        video.play(gone, matrix: service, from: timeline)
        #expect(video.eventID == "$gone")
        #expect(await eventually { video.eventID == nil })
        #expect(video.player == nil)
    }

    @Test("Leaving the timeline it plays in stops the video; leaving another doesn't")
    func leavingStops() async throws {
        let (service, _) = try await videoConversation()
        video.play(try #require(service.messages.first), matrix: service, from: timeline)
        #expect(await eventually { video.player != nil })
        let playing = try #require(video.player)

        video.stop(from: NSObject())
        #expect(video.player === playing)
        video.stop(from: timeline)
        #expect(video.eventID == nil && video.player == nil && playing.rate == 0)
    }
}
