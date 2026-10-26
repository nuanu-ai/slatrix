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
            // A focused field brings up AutoFill in a remote view, whose replies crash a process that never ran
            // NSApp's run loop.
            UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicsEnabled": false])
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

        func pressEscape() { press(53, "\u{1b}") }

        /// A key press as the app delivers it: key equivalents such as a default button first, then the focused view.
        func press(_ keyCode: UInt16, _ characters: String) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
                if type == .keyDown, window.performKeyEquivalent(with: event) { continue }
                window.sendEvent(event)
            }
        }

        /// The text field holding the cursor, through the field editor that stands in for it.
        var editingField: NSTextField? { (window.firstResponder as? NSTextView)?.delegate as? NSTextField }

        /// Where the destructive red is drawn, in the window's top-left coordinates; SwiftUI draws buttons without views
        /// to find.
        func redFrame() -> CGRect? {
            hosting.layoutSubtreeIfNeeded()
            guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            let scale = CGFloat(image.pixelsWide) / hosting.bounds.width
            var found = CGRect.null
            for x in stride(from: 0, to: image.pixelsWide, by: 2) {
                for y in stride(from: 0, to: image.pixelsHigh, by: 2) {
                    guard let pixel = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if pixel.redComponent > 0.7 && pixel.redComponent - pixel.greenComponent > 0.4 {
                        found = found.union(CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1, height: 1))
                    }
                }
            }
            return found.isNull ? nil : found
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
            host.press(UInt16(code), String(UnicodeScalar(key)!))
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

    // MARK: Modals

    @Observable @MainActor final class Probe {
        var shown = true
        var confirmed = false
        var name = ""
        var tab = 0
    }

    /// A form in a modal over a window that has a field and a text view of its own.
    private struct FormModal: View {
        @Bindable var probe: Probe
        var closesOnClickOutside = false
        var body: some View {
            ModalHost {
                VStack {
                    TextField("Behind", text: .constant("")).textFieldStyle(.field)
                    BehindText()
                }.padding(16).frame(width: 800, height: 600, alignment: .top).background(Color.white)
                    .modal(isPresented: $probe.shown, closesOnClickOutside: closesOnClickOutside) {
                        Modal(
                            title: "Create a channel", onClose: { probe.shown = false },
                            secondary: ModalAction("Cancel") { probe.shown = false },
                            primary: ModalAction("Create channel") { probe.confirmed = true }
                        ) {
                            TextField("Topic", text: $probe.name).textFieldStyle(.field)
                            TextField("Purpose", text: .constant("")).textFieldStyle(.field)
                        }
                    }
            }
        }
    }

    /// Selectable text under the modal, like a message, which AppKit could otherwise tab into.
    private struct BehindText: NSViewRepresentable {
        func makeNSView(context: Context) -> NSTextView {
            let view = NSTextView()
            view.string = "A message"
            view.isEditable = false
            return view
        }
        func updateNSView(_ view: NSTextView, context: Context) {}
    }

    private func formHost(_ probe: Probe, closesOnClickOutside: Bool = false) async -> Host {
        let host = Host(
            FormModal(probe: probe, closesOnClickOutside: closesOnClickOutside), size: CGSize(width: 800, height: 600))
        #expect(await eventually { host.editingField != nil })
        return host
    }

    @Test("A modal opens with the cursor in its first field")
    func modalFocusesFirstField() async {
        let host = await formHost(Probe())
        defer { host.close() }
        #expect(host.editingField?.placeholderString == "Topic")
    }

    @Test("Tab moves between the modal's fields and never behind it")
    func modalKeepsFocus() async {
        let host = await formHost(Probe())
        defer { host.close() }
        var visited: [String?] = []
        for _ in 0..<4 {
            host.press(48, "\t")
            await drainMainActor()
            visited.append(host.editingField?.placeholderString)
        }
        #expect(visited == ["Purpose", "Topic", "Purpose", "Topic"])
    }

    @Test("Esc closes a modal without its action")
    func modalEscapeCancels() async {
        let probe = Probe()
        let host = await formHost(probe)
        defer { host.close() }
        host.pressEscape()
        #expect(await eventually { !probe.shown })
        #expect(!probe.confirmed)
    }

    @Test("Return runs a modal's primary action")
    func modalReturnConfirms() async {
        let probe = Probe()
        let host = await formHost(probe)
        defer { host.close() }
        host.press(36, "\r")
        #expect(await eventually { probe.confirmed })
    }

    @Test("A click outside a form keeps it open with what was typed")
    func modalKeepsInputOnOutsideClick() async {
        let probe = Probe()
        let host = await formHost(probe)
        defer { host.close() }
        host.window.firstResponder?.insertText("design-team")
        await host.click(CGPoint(x: 20, y: 580))
        await drainMainActor()
        #expect(probe.shown)
        #expect(probe.name == "design-team")
    }

    @Test("A click outside closes a modal that asks for it")
    func modalClosesOnOutsideClick() async {
        let probe = Probe()
        let host = await formHost(probe, closesOnClickOutside: true)
        defer { host.close() }
        await host.click(CGPoint(x: 20, y: 580))
        #expect(await eventually { !probe.shown })
    }

    private struct Confirmation: View {
        @Bindable var probe: Probe
        var body: some View {
            ModalHost {
                Color.white.frame(width: 600, height: 400)
                    .modal(isPresented: $probe.shown) {
                        ConfirmModal(
                            title: "Delete message?", message: "This can’t be undone.", action: "Delete",
                            onConfirm: {
                                probe.confirmed = true
                                probe.shown = false
                            }, onCancel: { probe.shown = false })
                    }
            }
        }
    }

    @Test("A confirmation runs its action from its red button only", arguments: [true, false])
    func confirmation(confirm: Bool) async throws {
        let probe = Probe()
        let host = Host(Confirmation(probe: probe), size: CGSize(width: 600, height: 400))
        defer { host.close() }
        _ = await eventually { host.redFrame() != nil }
        let button = try #require(host.redFrame())
        // Cancel sits just left of it.
        await host.click(CGPoint(x: confirm ? button.midX : button.minX - 32, y: button.midY))
        #expect(await eventually { !probe.shown })
        #expect(probe.confirmed == confirm)
    }

    private struct Tabs: View {
        @Bindable var probe: Probe
        var body: some View {
            TabBar(
                tabs: [
                    .init(value: 0, title: "About"), .init(value: 1, title: "Members", count: 4),
                    .init(value: 2, title: "Settings"),
                ], selection: $probe.tab
            ).padding(16).frame(width: 400, height: 100).background(Color.white)
        }
    }

    @Test("Arrow keys move between tabs once the tab bar has focus")
    func tabBarArrows() async {
        let probe = Probe()
        let host = Host(Tabs(probe: probe), size: CGSize(width: 400, height: 100))
        defer { host.close() }
        // A click on "About", the first tab, focuses the bar.
        await host.click(CGPoint(x: 32, y: 50))
        #expect(await eventually { host.window.firstResponder !== host.window })
        var visited: [Int] = []
        for (code, key) in [(124, "\u{F703}"), (124, "\u{F703}"), (123, "\u{F702}")] {
            host.press(UInt16(code), key)
            await drainMainActor()
            visited.append(probe.tab)
        }
        #expect(visited == [1, 2, 1])
    }
}
