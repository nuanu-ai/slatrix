import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// Later in a real offscreen window, over the sample workspace; needs an awake display.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct SavedMessagesHostedTests {
    @Test("A click anywhere on a saved message opens it, as in Slack")
    func clickOnMessageOpensIt() async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.enterPreview()
        matrix.selectPreviewRoom(PreviewMedia.roomID)
        let message = try #require(matrix.messages.first { !$0.body.isEmpty })
        let reference = SavedMessageReference(roomID: message.roomID, eventID: message.eventID)
        var opened: SavedMessageReference?
        let hosting = NSHostingView(
            rootView: SavedMessagesView(
                matrix: matrix, saved: [reference], onOpen: { opened = $0 }, onRemove: { _ in }
            ).environmentObject(AppearanceStore()))
        let window = offscreenWindow(NSSize(width: 700, height: 500))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        // On the message's text, which a text view would otherwise keep for selecting.
        var location = NSPoint.zero
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        #expect(
            await eventually {
                hosting.layoutSubtreeIfNeeded()
                guard let text = views(hosting).first(where: { $0 is MessageTextView }) else { return false }
                location = text.convert(NSPoint(x: text.bounds.midX, y: text.bounds.midY), to: nil)
                return true
            })
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            await drainMainActor()
            window.sendEvent(
                try #require(
                    NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        #expect(await eventually { opened == reference })
    }
}
