import AVFoundation
import AVKit
import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// Shows two videos in a conversation over the fake client: playable, each a minute long so none ends mid-test, or
/// with `file` as what their download holds.
@MainActor
func videoConversation(file: Data? = nil) async throws -> (MatrixService, TemporaryDirectory) {
    let roomID = "!videos:example.org"
    let folder = try TemporaryDirectory()
    let client = FakeClient(rooms: [FakeRoom(roomInfo(id: roomID))])
    if let file {
        client.file = file
    } else {
        client.file = try Data(
            contentsOf: try await folder.video("clip.mov", width: 32, height: 18, rotation: 0, seconds: 60))
    }
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

    @Test("A video that won't play goes back to its poster and says so")
    func unplayable() async throws {
        let (service, _) = try await videoConversation(file: Data("not a movie".utf8))
        video.play(try #require(service.messages.first), matrix: service, from: timeline)
        #expect(await eventually { video.player != nil })
        #expect(await eventually { video.eventID == nil && service.errorMessage != nil })
        #expect(video.player == nil)
    }

    @Test("The row's player stays clear until its video plays, so the poster shows instead of a black box")
    func clearUntilPlaying() async throws {
        let folder = try TemporaryDirectory()
        let player = AVPlayer(
            url: try await folder.video("clip.mov", width: 32, height: 18, rotation: 0, seconds: 60))
        let view = InlinePlayerView()
        view.player = player
        #expect(view.alphaValue == 0)
        player.play()
        #expect(await eventually { view.alphaValue == 1 })
    }

    @Test("A video shown in both the channel and a thread plays only in the pane it was started from")
    func onePane() async throws {
        let (service, _) = try await videoConversation()
        let message = try #require(service.messages.first)
        let channel = video.slot(message, matrix: service, in: timeline)
        let thread = video.slot(message, matrix: service, in: NSObject())
        channel.play()
        #expect(await eventually { channel.player != nil })
        #expect(!thread.isPlaying && thread.player == nil)
    }

    @Test("Opening the viewer pauses the video playing in its row")
    func viewerPauses() async throws {
        let (service, _) = try await videoConversation()
        let viewer = MediaViewerState()
        viewer.inlineVideo.play(try #require(service.messages.first), matrix: service, from: timeline)
        #expect(await eventually { (viewer.inlineVideo.player?.rate ?? 0) > 0 })
        viewer.open(try #require(service.messages.last), surface: .conversation)
        #expect(viewer.inlineVideo.player?.rate == 0)
    }

    @Test("The viewer opened on the video playing in its row carries on from where it was, and others start at the top")
    func viewerCarriesOn() async throws {
        let (service, _) = try await videoConversation()
        let viewer = MediaViewerState()
        let message = try #require(service.messages.first)
        viewer.inlineVideo.play(message, matrix: service, from: timeline)
        #expect(await eventually { (viewer.inlineVideo.player?.currentTime().seconds ?? 0) > 0.2 })
        viewer.open(message, surface: .conversation)
        let paused = try #require(viewer.inlineVideo.player).currentTime()
        // Within a frame: the player drifts a little after pausing.
        #expect(abs((viewer.videoStart(message) - paused).seconds) < 1.0 / 30)
        #expect(viewer.videoStart(try #require(service.messages.last)) == .zero)
    }

    @Test("The viewer's video starts at the time it is given")
    func stageStartsThere() async throws {
        let folder = try TemporaryDirectory()
        let url = try await folder.video("clip.mov", width: 32, height: 18, rotation: 0, seconds: 60)
        let stage = MediaStageView()
        stage.show(.video(url, from: CMTime(seconds: 30, preferredTimescale: 600)))
        let view = try #require(stage.subviews.lazy.compactMap { $0 as? AVPlayerView }.first)
        #expect(await eventually { (view.player?.currentTime().seconds ?? 0) >= 30 })
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
