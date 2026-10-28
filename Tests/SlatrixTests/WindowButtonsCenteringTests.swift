import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// The window buttons against a bare title bar along the top of a titled window, without the rest of the window.
@MainActor
struct WindowButtonsCenteringTests {
    @Test(
        "The window buttons hold the title bar's midline on every frame of a resize from any edge",
        // The bar at 100% and 150% zoom.
        arguments: [40.0, 60.0])
    func holdThroughResize(barHeight: Double) async throws {
        let window = offscreenWindow(
            NSSize(width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        defer { window.close() }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Hosted, as the app's window is: SwiftUI sizes its views in the window's layout pass, after the frame.
        let hosting = NSHostingView(
            rootView: Color.clear.frame(height: barHeight).background(WindowButtonsCentering())
                .frame(maxHeight: .infinity, alignment: .top))
        window.contentView = hosting
        let close = try #require(window.standardWindowButton(.closeButton))
        func offset() -> CGFloat { close.convert(close.bounds, to: nil).midY - (hosting.bounds.height - barHeight / 2) }
        #expect(await eventually { abs(offset()) <= 1 }, "\(offset())")

        // A live resize sets the window's frame and draws it in one go, so each frame is checked right after, with
        // no turn of the run loop between. Dragging the left edge changes the width, the top edge the height, and
        // the top left corner both. Only the size reaches the views, so the other edges and corners take these paths.
        for (edge, widthChange, heightChange) in [("left", -20.0, 0.0), ("top", 0, -20), ("corner", -20, -20)] {
            for step in 1...3 {
                let frame = window.frame
                window.setFrame(
                    NSRect(
                        x: frame.minX - widthChange, y: frame.minY, width: frame.width + widthChange,
                        height: frame.height + heightChange), display: true)
                #expect(abs(offset()) <= 1, "\(edge), step \(step): \(offset())")
            }
        }
    }
}
