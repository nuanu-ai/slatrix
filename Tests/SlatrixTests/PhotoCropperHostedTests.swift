import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// Crop your photo in a real offscreen window; needs an awake display.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct PhotoCropperHostedTests {
    // capability: profile.edit-photo
    @Test("Dragging the frame and a corner changes the crop, and Return saves it")
    func dragThenSave() async throws {
        _ = NSApplication.shared
        let folder = try TemporaryDirectory()
        let image = try ProfilePhoto.image(contentsOf: folder.png("photo.png", width: 300, height: 200))
        var saved: CGRect?
        let hosting = NSHostingView(
            rootView: ModalHost {
                Color.white.frame(width: 900, height: 700).modal(isPresented: .constant(true)) {
                    PhotoCropper(image: image, onCancel: {}, onSave: { saved = $0 })
                }
            }.environmentObject(AppearanceStore()))
        let window = offscreenWindow(NSSize(width: 900, height: 700))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func surface() -> NSView? {
            hosting.layoutSubtreeIfNeeded()
            return views(hosting).first { String(describing: type(of: $0)) == "CropSurfaceView" }
        }
        #expect(await eventually { surface() != nil })
        // The photo fills the surface, so its middle is the middle of the centered frame.
        let photo = try #require(surface()).convert(try #require(surface()).bounds, to: nil)
        let middle = NSPoint(x: photo.midX, y: photo.midY)

        // The app window moves by its background, and the window server, not sendEvent, decides which clicks drag it.
        window.isMovableByWindowBackground = true
        let hit = try #require(hosting.hitTest(hosting.convert(middle, from: nil)))
        #expect(!hit.mouseDownCanMoveWindow)

        func drag(from start: NSPoint, to end: NSPoint) async throws {
            for (type, point) in [
                (NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end),
            ] {
                await drainMainActor()
                window.sendEvent(
                    try #require(
                        NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            await drainMainActor()
        }
        // Far right: the frame stops at the photo's right edge.
        try await drag(from: middle, to: NSPoint(x: middle.x + photo.width, y: middle.y))
        // Then its bottom-left corner, a photo-height from the right edge, up and to the right.
        let corner = NSPoint(x: photo.maxX - photo.height + 2, y: photo.minY + 2)
        try await drag(from: corner, to: NSPoint(x: corner.x + photo.height / 4, y: corner.y + photo.height / 4))

        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r",
                    isARepeat: false, keyCode: 36))
            if type == .keyDown, window.performKeyEquivalent(with: event) { continue }
            window.sendEvent(event)
        }
        #expect(await eventually { saved != nil })
        let crop = try #require(saved)
        #expect(abs(crop.maxX - 300) < 1)
        #expect(abs(crop.minY) < 1)
        #expect(abs(crop.width - 150) < 1)
        #expect(crop.width == crop.height)
    }
}
