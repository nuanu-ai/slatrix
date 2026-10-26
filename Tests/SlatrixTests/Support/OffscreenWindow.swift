import AppKit

/// A window far off every screen, so hosted tests never flash on the screen of whoever runs them. It stays
/// borderless because AppKit drags a titled window back onto a screen when it is ordered in.
func offscreenWindow(_ size: NSSize) -> NSWindow {
    let window = KeyableWindow(
        contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size), styleMask: .borderless,
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
}

/// Borderless windows refuse key status by default, and focus and key events need it.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
