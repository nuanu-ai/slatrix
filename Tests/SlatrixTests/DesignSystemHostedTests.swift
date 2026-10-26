import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// Design system components in a real offscreen window; needs an awake display.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct DesignSystemHostedTests {
    @MainActor private final class Host {
        let window: NSWindow
        let hosting: NSView

        init(_ view: some View, size: CGSize) {
            _ = NSApplication.shared
            hosting = NSHostingView(rootView: view.environmentObject(AppearanceStore()))
            window = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), styleMask: .titled,
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
        }

        func close() {
            window.contentView = nil
            window.close()
        }

        /// Whether any pixel has the focus ring's cyan blue, whose green stands well above its red; the accent's blue
        /// in link text doesn't.
        func showsFocusRing() -> Bool {
            hosting.layoutSubtreeIfNeeded()
            guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            for x in 0..<image.pixelsWide {
                for y in 0..<image.pixelsHigh {
                    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if color.blueComponent - color.redComponent > 0.3
                        && color.greenComponent - color.redComponent > 0.15
                    {
                        return true
                    }
                }
            }
            return false
        }

        /// A click at `point`, in the window's top-left coordinates.
        func click(_ point: CGPoint) async {
            let location = CGPoint(x: point.x, y: hosting.bounds.height - point.y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                await drainMainActor()
                window.sendEvent(
                    NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
        }

        func pressEscape() {
            window.sendEvent(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        }
    }

    @Test(
        "Every button shows a focus ring when focused, and only then",
        arguments: [InteractionState.focused, .rest, .hover, .pressed])
    func focusRing(state: InteractionState) {
        let host = Host(
            VStack(spacing: 16) {
                ForEach(ButtonKind.allCases, id: \.self) { kind in ButtonChrome(kind: kind, state: state) { Text("Go") }
                }
                IconChrome(state: state) { Image(systemName: "xmark").frame(width: 28, height: 28) }
            }.padding(16).frame(width: 200, height: 260).background(Color.white),
            size: CGSize(width: 200, height: 260))
        defer { host.close() }
        #expect(host.showsFocusRing() == (state == .focused))
    }

    private func popoverHost(_ popovers: Popovers) -> Host {
        Host(
            PopoverHost(popovers: popovers) {
                Color.white.frame(width: 800, height: 600)
            } card: { _ in
                Color.gray.frame(height: 120)
            },
            size: CGSize(width: 800, height: 600))
    }

    @Test("Esc closes the card")
    func escapeCloses() async {
        let popovers = Popovers()
        let host = popoverHost(popovers)
        defer { host.close() }
        popovers.show(.profile(userID: "@alice:example.org", fallback: nil), at: CGPoint(x: 100, y: 100))
        #expect(await eventually { host.window.firstResponder !== host.window })
        host.pressEscape()
        #expect(await eventually { popovers.current == nil })
    }

    @Test("A click outside the card closes it; a click on it doesn't")
    func clickOutsideCloses() async {
        let popovers = Popovers()
        let host = popoverHost(popovers)
        defer { host.close() }
        // The card sits right of and a little above the anchor: about x 112–432, y 76–228.
        popovers.show(.profile(userID: "@alice:example.org", fallback: nil), at: CGPoint(x: 100, y: 100))
        #expect(await eventually { host.window.firstResponder !== host.window })
        await host.click(CGPoint(x: 250, y: 150))
        await drainMainActor()
        #expect(popovers.current != nil)
        await host.click(CGPoint(x: 700, y: 500))
        #expect(await eventually { popovers.current == nil })
    }
}
