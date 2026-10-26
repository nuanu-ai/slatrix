import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// The Files view and the media viewer in a real offscreen window, over the sample workspace; needs an awake display.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct SharedFilesHostedTests {
    @Test("A click on a file row opens it in the viewer, and → steps to the file in the next row")
    func clickOpensViewer() async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.enterPreview()
        matrix.selectPreviewRoom(PreviewMedia.roomID)
        let viewer = MediaViewerState()
        let hosting = NSHostingView(
            rootView: ZStack {
                SharedFilesView(
                    matrix: matrix, service: matrix.sharedFiles, workspaceID: nil, onOpen: { _ in },
                    onOpenMedia: { viewer.open($0, files: $1) })
                MediaViewer(matrix: matrix, viewer: viewer, onForward: { _ in })
            }.environmentObject(AppearanceStore()))
        let window = offscreenWindow(NSSize(width: 900, height: 700))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }

        // The guidelines row is the one with a PDF's red tile.
        var tile: CGPoint?
        #expect(
            await eventually {
                tile = redPoint(in: hosting)
                return tile != nil
            })
        let location = try #require(tile)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            await drainMainActor()
            window.sendEvent(
                try #require(
                    NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        #expect(await eventually { viewer.message?.id == "preview.pdf" })

        #expect(
            await eventually {
                hosting.layoutSubtreeIfNeeded()
                return window.firstResponder is MediaStageView
            })
        window.sendEvent(
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{F703}",
                    charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)))
        // The list runs newest first, and the walkthrough video was shared just before the guidelines.
        #expect(await eventually { viewer.message?.id == "preview.video" })
    }

    /// The first point, in window coordinates, drawn in a clear red; in the sample only a PDF's tile is.
    private func redPoint(in view: NSView) -> CGPoint? {
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: image)
        let scale = CGFloat(image.pixelsWide) / view.bounds.width
        for y in stride(from: 0, to: image.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: image.pixelsWide, by: 2) {
                guard let pixel = image.colorAt(x: x, y: y) else { continue }
                if pixel.redComponent - pixel.greenComponent > 0.4 && pixel.redComponent - pixel.blueComponent > 0.4 {
                    // A few points in, past the tile's rounded corner.
                    return CGPoint(x: CGFloat(x) / scale + 4, y: view.bounds.height - CGFloat(y) / scale - 4)
                }
            }
        }
        return nil
    }
}
