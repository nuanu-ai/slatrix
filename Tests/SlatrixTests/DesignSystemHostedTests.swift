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

        func pressEscape() { press("\u{1b}", keyCode: 53) }

        func press(_ characters: String, keyCode: UInt16) {
            window.sendEvent(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!)
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

    private struct FocusedCard: View {
        @FocusState private var focused: Bool
        var body: some View {
            VStack(spacing: 16) {
                Button("Row") {}.buttonStyle(.row)
                Button("More") {}.buttonStyle(.secondary)
                IconButton(symbol: "xmark", label: "Close") {}
            }
            .padding(16).frame(width: 200, height: 200).background(Color.white)
            .focusable().focusEffectDisabled().focused($focused).onAppear { focused = true }
        }
    }

    @Test(
        "Buttons in a focused card show no ring while the Mac's keyboard navigation is off",
        .enabled(if: !NSApplication.shared.isFullKeyboardAccessEnabled))
    func noRingWithoutKeyboardNavigation() async {
        let host = Host(FocusedCard(), size: CGSize(width: 200, height: 200))
        defer { host.close() }
        #expect(await eventually { host.window.firstResponder !== host.window })
        #expect(!host.showsFocusRing())
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

    @Test("The emoji picker opens ready to search; arrows move, Return picks and Esc closes")
    func emojiPickerKeyboard() async throws {
        let popovers = Popovers()
        let picked = Recorder<String>()
        let host = Host(
            PopoverHost(popovers: popovers) {
                Color.white.frame(width: 800, height: 600)
            } card: { kind in
                if case .emoji(let pick) = kind {
                    EmojiPicker(recent: ["🎉"]) { emoji in
                        popovers.close()
                        pick.action(emoji)
                    }
                }
            },
            size: CGSize(width: 800, height: 600))
        defer { host.close() }
        popovers.show(.emoji(EmojiPick { picked.append($0) }), at: CGPoint(x: 100, y: 100))
        // Typing goes straight to the search field.
        #expect(await eventually { host.window.firstResponder is NSTextView })
        let field = try #require(host.window.firstResponder as? NSTextView)
        field.insertText("heart", replacementRange: field.selectedRange())
        await drainMainActor()
        let results = EmojiCatalog.search("heart").map(\.value)
        // Each key acts on what the last one left on screen.
        for (key, code) in [(NSRightArrowFunctionKey, 124), (NSDownArrowFunctionKey, 125), (13, 36)] {
            host.hosting.layoutSubtreeIfNeeded()
            await drainMainActor()
            host.press(String(UnicodeScalar(key)!), keyCode: UInt16(code))
        }
        // One right and one row of nine down from the top result.
        #expect(await eventually { picked.all == [results[10]] })
        #expect(popovers.current == nil)

        popovers.show(.emoji(EmojiPick { picked.append($0) }), at: CGPoint(x: 100, y: 100))
        #expect(await eventually { host.window.firstResponder is NSTextView })
        host.pressEscape()
        #expect(await eventually { popovers.current == nil })
        #expect(picked.all.count == 1)
    }

    /// A plain text view, as the composer is.
    private struct Editor: NSViewRepresentable {
        let view: NSTextView
        func makeNSView(context: Context) -> NSTextView { view }
        func updateNSView(_ view: NSTextView, context: Context) {}
    }

    @Test("Closing the emoji picker with Esc puts focus back where it was")
    func escapeRestoresFocus() async {
        let popovers = Popovers()
        let composer = NSTextView()
        let host = Host(
            PopoverHost(popovers: popovers) {
                Editor(view: composer).frame(width: 800, height: 600)
            } card: { _ in
                EmojiPicker(recent: []) { _ in }
            },
            size: CGSize(width: 800, height: 600))
        defer { host.close() }
        host.hosting.layoutSubtreeIfNeeded()
        host.window.makeFirstResponder(composer)
        #expect(host.window.firstResponder === composer)
        popovers.show(.emoji(EmojiPick { _ in }), at: CGPoint(x: 100, y: 100))
        #expect(await eventually { (host.window.firstResponder as? NSTextView)?.isFieldEditor == true })
        host.pressEscape()
        #expect(await eventually { popovers.current == nil })
        #expect(await eventually { host.window.firstResponder === composer })
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
