import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// The media viewer in a real offscreen window, driven by the keys a person presses; needs an awake display.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct MediaViewerHostedTests {
    private func media(_ id: String, kind: String, mime: String) -> ChatMessage {
        ChatMessage(
            id: id, roomID: "!r:example.org", senderID: "@a:example.org", senderName: "Alex", body: id,
            timestamp: Date(timeIntervalSince1970: 1_761_192_000), kind: kind,
            attachment: MessageAttachment(
                name: id, url: "mxc://example.org/\(id.dropFirst())", mimeType: mime, width: 800, height: 600))
    }

    private func press(_ keyCode: UInt16, _ characters: String, in window: NSWindow) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: keyCode))
        window.sendEvent(event)
    }

    // capability: message.media-viewer
    @Test("The arrow keys step through the conversation's images and videos, and Esc closes the viewer")
    func keys() async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.messages = [
            media("$photo", kind: "m.image", mime: "image/png"),
            media("$report", kind: "m.file", mime: "application/pdf"),
            media("$clip", kind: "m.video", mime: "video/mp4"),
        ]
        let viewer = MediaViewerState()
        viewer.open(matrix.messages[0], surface: .conversation)
        let hosting = NSHostingView(
            rootView: MediaViewer(matrix: matrix, viewer: viewer, onForward: { _ in })
                .environmentObject(AppearanceStore()))
        let window = offscreenWindow(NSSize(width: 900, height: 600))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        #expect(
            await eventually {
                hosting.layoutSubtreeIfNeeded()
                return window.firstResponder is MediaStageView
            })

        try press(124, "\u{F703}", in: window)
        #expect(await eventually { viewer.message?.eventID == "$clip" })
        try press(124, "\u{F703}", in: window)
        await drainMainActor()
        #expect(viewer.message?.eventID == "$clip")
        try press(123, "\u{F702}", in: window)
        #expect(await eventually { viewer.message?.eventID == "$photo" })
        try press(53, "\u{1B}", in: window)
        #expect(await eventually { viewer.message == nil })
    }
}
