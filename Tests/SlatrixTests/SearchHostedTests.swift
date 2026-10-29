import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// ⌘K and the top bar's search in the whole window, offscreen, over the sample workspace; needs an awake display.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct SearchHostedTests {
    @MainActor private final class Harness {
        let matrix = MatrixService()
        let window: NSWindow
        let hosting: NSHostingView<AnyView>

        init() {
            _ = NSApplication.shared
            // A focused field brings up AutoFill in a remote view, whose replies crash a process that never ran
            // NSApp's run loop.
            UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicsEnabled": false])
            matrix.enterPreview()
            hosting = NSHostingView(rootView: AnyView(RootView(matrix: matrix).environmentObject(AppearanceStore())))
            window = offscreenWindow(NSSize(width: 1_440, height: 900))
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
        }

        func close() {
            window.contentView = nil
            window.close()
        }

        /// The text field with this placeholder, once the window shows it.
        func field(_ placeholder: String) async -> NSTextField? {
            _ = await eventually {
                hosting.layoutSubtreeIfNeeded()
                return fields().contains { $0.placeholderString == placeholder }
            }
            return fields().first { $0.placeholderString == placeholder }
        }

        func fields() -> [NSTextField] { Self.views(in: hosting).compactMap { $0 as? NSTextField } }

        /// The text field holding the cursor, through the field editor that stands in for it.
        var editingField: NSTextField? { (window.firstResponder as? NSTextView)?.delegate as? NSTextField }

        func type(_ text: String) { window.firstResponder?.insertText(text) }

        /// A key press as the app delivers it: key equivalents first, then the focused view.
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
        func pressDown() { press(125, "\u{F701}") }
        func pressReturn() { press(36, "\r") }
        func pressEscape() { press(53, "\u{1b}") }

        func menu(_ action: String) {
            NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": action])
        }

        /// The pixels just below `field`, where its menu drops: SwiftUI draws the menu's rows without views to find.
        func pixelsBelow(_ field: NSTextField) -> [NSColor?] {
            hosting.layoutSubtreeIfNeeded()
            let frame = field.convert(field.bounds, to: hosting)
            let area = CGRect(x: frame.minX, y: frame.maxY + 8, width: frame.width, height: 24)
            guard let image = hosting.bitmapImageRepForCachingDisplay(in: area) else { return [] }
            hosting.cacheDisplay(in: area, to: image)
            return stride(from: 0, to: image.pixelsWide, by: 4).flatMap { x in
                stride(from: 0, to: image.pixelsHigh, by: 4).map { image.colorAt(x: x, y: $0) }
            }
        }

        /// The frames of the window's scroll views and fields, which a menu pushing content down would move.
        func layout() -> [CGRect] {
            hosting.layoutSubtreeIfNeeded()
            return Self.views(in: hosting).filter { $0 is NSScrollView || $0 is NSTextField }.map {
                $0.convert($0.bounds, to: nil)
            }
        }

        static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    }

    // capability: search.rooms
    @Test("⌘K opens Jump to with the cursor in its field, and ↓ and Return open the conversation picked")
    func switcherOpensConversation() async throws {
        let harness = Harness()
        defer { harness.close() }
        _ = await harness.field("Search Harbor")
        harness.menu("search")
        #expect(await eventually { harness.editingField?.placeholderString == "Jump to…" })
        // "de" finds Design first, then Planning and Demos by its last word.
        harness.type("de")
        await drainMainActor()
        harness.pressDown()
        await drainMainActor()
        harness.pressReturn()
        #expect(await eventually { harness.matrix.selectedRoomID == "preview.room.5" })
        #expect(await eventually { !harness.fields().contains { $0.placeholderString == "Jump to…" } })
    }

    @Test("Esc closes Jump to, even with a query typed")
    func switcherEscapeCloses() async throws {
        let harness = Harness()
        defer { harness.close() }
        _ = await harness.field("Search Harbor")
        harness.menu("search")
        #expect(await eventually { harness.editingField?.placeholderString == "Jump to…" })
        harness.type("de")
        await drainMainActor()
        harness.pressEscape()
        #expect(await eventually { !harness.fields().contains { $0.placeholderString == "Jump to…" } })
        #expect(harness.matrix.selectedRoomID == "preview.room.0")
    }

    @Test("Typing in the top bar drops its menu over the window without moving anything in it")
    func barMenuFloats() async throws {
        let harness = Harness()
        defer { harness.close() }
        let bar = try #require(await harness.field("Search Harbor"))
        let layout = harness.layout()
        let closed = harness.pixelsBelow(bar)
        harness.window.makeFirstResponder(bar)
        harness.type("de")
        #expect(await eventually { harness.pixelsBelow(bar) != closed })
        #expect(harness.layout() == layout)
    }

    @Test("A click on a conversation in the top bar's menu opens it")
    func barMenuClickOpens() async throws {
        let harness = Harness()
        defer { harness.close() }
        let bar = try #require(await harness.field("Search Harbor"))
        let closed = harness.pixelsBelow(bar)
        harness.window.makeFirstResponder(bar)
        harness.type("de")
        #expect(await eventually { harness.pixelsBelow(bar) != closed })
        // Rows are 32 pt under an 8 pt inset, 4 pt below the bar: the search, then Design.
        let frame = bar.convert(bar.bounds, to: harness.hosting)
        let design = CGPoint(x: frame.midX, y: harness.hosting.bounds.height - (frame.maxY + 4 + 8 + 32 + 16))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            await drainMainActor()
            harness.window.sendEvent(
                NSEvent.mouseEvent(
                    with: type, location: design, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1)!)
        }
        #expect(await eventually { harness.matrix.selectedRoomID == "preview.room.2" })
    }

    @Test("Esc in the top bar clears what was typed, then closes the menu")
    func barEscape() async throws {
        let harness = Harness()
        defer { harness.close() }
        let bar = try #require(await harness.field("Search Harbor"))
        let closed = harness.pixelsBelow(bar)
        harness.window.makeFirstResponder(bar)
        harness.type("de")
        #expect(await eventually { harness.pixelsBelow(bar) != closed })
        harness.pressEscape()
        #expect(await eventually { bar.stringValue.isEmpty })
        #expect(harness.editingField === bar)
        harness.pressEscape()
        #expect(await eventually { harness.editingField !== bar && harness.pixelsBelow(bar) == closed })
    }

    @Test("Return in the top bar shows message results in the main pane")
    func barReturnSearches() async throws {
        let harness = Harness()
        defer { harness.close() }
        let bar = try #require(await harness.field("Search Harbor"))
        harness.window.makeFirstResponder(bar)
        harness.type("team")
        await drainMainActor()
        harness.pressReturn()
        // Only the results page searches messages.
        #expect(await eventually { !harness.matrix.searchResults.isEmpty })
    }
}
