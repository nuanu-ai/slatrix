import AVKit
import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// A video row in a real offscreen window, inside a scroll view as the timeline's rows are; needs an awake display.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct InlineVideoHostedTests {
    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    // capability: message.video
    @Test("A click plays the video in its own box without moving anything, and scrolling it away pauses it")
    func playsInPlace() async throws {
        _ = NSApplication.shared
        let (matrix, _) = try await videoConversation()
        let message = try #require(matrix.messages.first)
        let attachment = try #require(message.attachment)
        let video = InlineVideo()
        let timeline = NSObject()
        // Measured at a width and its own height, as the timeline measures its rows.
        let host = NSHostingController(
            rootView: AttachmentView(
                matrix: matrix, message: message, attachment: attachment,
                actions: AttachmentActions(inlineVideo: video.slot(message, matrix: matrix, in: timeline))
            ).fixedSize(horizontal: false, vertical: true).environmentObject(AppearanceStore()))
        host.sizingOptions = []
        let row = host.view
        func measured() -> CGFloat { host.sizeThatFits(in: CGSize(width: 600, height: 0)).height }
        let height = measured()
        row.frame = CGRect(x: 0, y: 0, width: 600, height: height)
        let document = Document(frame: CGRect(x: 0, y: 0, width: 600, height: height + 2_000))
        document.addSubview(row)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = document
        let window = offscreenWindow(NSSize(width: 600, height: 400))
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }

        row.layoutSubtreeIfNeeded()
        // The middle of the 320×180 box under the name, which the row centers.
        let location = row.convert(CGPoint(x: 300, y: height - 90), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            await drainMainActor()
            window.sendEvent(
                try #require(
                    NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        #expect(await eventually { (video.player?.rate ?? 0) > 0 })
        var shown: AVPlayerView?
        #expect(
            await eventually {
                row.layoutSubtreeIfNeeded()
                shown = playerView(in: row)
                return shown != nil
            })
        let frame = try #require(shown).convert(try #require(shown).bounds, to: row)
        #expect(abs(frame.width - 320) < 1 && abs(frame.height - 180) < 1)
        #expect(measured() == height)

        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1_500))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(await eventually { video.player?.rate == 0 })
    }

    @Test("A copy of the row left behind in a reused cell never pauses the video being watched")
    func staleCopy() async throws {
        let folder = try TemporaryDirectory()
        let player = AVPlayer(
            url: try await folder.video("clip.mov", width: 32, height: 18, rotation: 0, seconds: 60))
        let window = offscreenWindow(NSSize(width: 400, height: 300))
        let stale = InlinePlayerView(frame: CGRect(x: 0, y: 0, width: 160, height: 90))
        let watched = InlinePlayerView(frame: CGRect(x: 0, y: 100, width: 160, height: 90))
        stale.player = player
        watched.player = player
        window.contentView?.addSubview(stale)
        window.contentView?.addSubview(watched)
        defer { window.close() }
        player.play()

        stale.removeFromSuperview()
        #expect(player.rate > 0)
        watched.removeFromSuperview()
        #expect(player.rate == 0)
    }

    private func playerView(in view: NSView) -> AVPlayerView? {
        if let player = view as? AVPlayerView { return player }
        return view.subviews.lazy.compactMap { playerView(in: $0) }.first
    }
}
