import AppKit

/// A window far off every screen, so hosted tests never flash on the screen of whoever runs them. Borderless unless
/// `styleMask` asks for the title bar and its window buttons.
func offscreenWindow(_ size: NSSize, styleMask: NSWindow.StyleMask = .borderless) -> NSWindow {
    let window = OffscreenWindow(
        contentRect: NSRect(origin: OffscreenWindow.origin, size: size), styleMask: styleMask, backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    // AppKit starts a titled window on a screen, whatever the content rect says.
    window.setFrameOrigin(OffscreenWindow.origin)
    return window
}

/// Borderless windows refuse key status by default, and focus and key events need it.
private final class OffscreenWindow: NSWindow {
    static let origin = NSPoint(x: -20_000, y: -20_000)

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // AppKit moves a titled window onto a screen when it orders it in, and a resize keeps the top edge where it was.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(NSRect(origin: Self.origin, size: frameRect.size), display: flag)
    }

    override func orderFrontRegardless() {
        precondition(offscreen, "\(frame) is on a screen")
        super.orderFrontRegardless()
        precondition(offscreen, "\(frame) is on a screen")
    }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWindow: Int) {
        precondition(place == .out || offscreen, "\(frame) is on a screen")
        super.order(place, relativeTo: otherWindow)
        precondition(offscreen, "\(frame) is on a screen")
    }

    private var offscreen: Bool { !NSScreen.screens.contains { $0.frame.intersects(frame) } }
}
