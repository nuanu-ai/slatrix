import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// The profile pane in the whole window, offscreen, over the sample workspace; needs an awake display.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct ProfilePaneHostedTests {
    // capability: people.profile
    @Test("A click on a sender's name opens their profile in the side pane, and Esc closes it")
    func senderNameOpensPane() async throws {
        _ = NSApplication.shared
        UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicsEnabled": false])
        let matrix = MatrixService()
        matrix.enterPreview()
        let hosting = NSHostingView(rootView: RootView(matrix: matrix).environmentObject(AppearanceStore()))
        let window = offscreenWindow(NSSize(width: 1_440, height: 900))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        // The sidebar's divider is always there; a side pane brings a second one.
        func dividers() -> Int {
            hosting.layoutSubtreeIfNeeded()
            return views(hosting).filter { String(describing: type(of: $0)) == "ResizePointerView" }.count
        }
        func welcome() -> MessageTextView? {
            hosting.layoutSubtreeIfNeeded()
            return views(hosting).compactMap { $0 as? MessageTextView }.first {
                $0.string.hasPrefix("Welcome to our new workspace") && $0.window != nil
            }
        }
        #expect(await eventually { welcome() != nil })
        #expect(dividers() == 1)

        // Alex's name sits on the line above the welcome's text.
        let text = try #require(welcome()).convert(try #require(welcome()).bounds, to: nil)
        let name = NSPoint(x: text.minX + 8, y: text.maxY + 12)
        func clickName() async throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                await drainMainActor()
                window.sendEvent(
                    try #require(
                        NSEvent.mouseEvent(
                            with: type, location: name, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
        }
        try await clickName()
        #expect(await eventually { dividers() == 2 })

        // Esc from the composer, where the cursor usually is.
        let composer = try #require(views(hosting).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        window.makeFirstResponder(composer)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            window.sendEvent(
                try #require(
                    NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        }
        #expect(await eventually { dividers() == 1 })

        // Esc from anywhere else, as the app's key monitor delivers it, even after leaving the conversation.
        try await clickName()
        #expect(await eventually { dividers() == 2 })
        func menu(_ action: String) {
            NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": action])
        }
        menu("people")
        await drainMainActor()
        #expect(dividers() == 2)
        menu("mark-read")
        #expect(await eventually { dividers() == 1 })
    }
}
