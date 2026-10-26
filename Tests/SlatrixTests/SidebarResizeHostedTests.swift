import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// The production sidebar in a real offscreen window; needs an awake display.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct SidebarResizeHostedTests {
    @Test("Clicking keeps the divider neutral, with no focus ring, and dragging widens the real sidebar")
    func clickAndDrag() async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.enterPreview()
        let savedWidth = UserDefaults.standard.object(forKey: "layout.sidebarWidth")
        UserDefaults.standard.set(280, forKey: "layout.sidebarWidth")
        defer { UserDefaults.standard.set(savedWidth, forKey: "layout.sidebarWidth") }
        let hosting = NSHostingView(rootView: RootView(matrix: matrix).environmentObject(AppearanceStore()))
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1_440, height: 900),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }

        _ = await eventually {
            hosting.layoutSubtreeIfNeeded()
            return pointer(in: hosting) != nil
        }
        let handle = try #require(pointer(in: hosting))
        let before = handle.convert(handle.bounds, to: hosting)
        // The app window moves by its background, and the window server, not sendEvent, decides which clicks
        // drag it; a divider that allowed it would never see a mouseDragged.
        window.isMovableByWindowBackground = true
        let hit = try #require(hosting.hitTest(NSPoint(x: before.midX, y: before.midY)))
        #expect(!hit.mouseDownCanMoveWindow)
        let neutralDivider = try image(hosting, in: before)
        let start = NSPoint(x: before.midX, y: before.midY)
        let responder = window.firstResponder
        window.sendEvent(try #require(mouseEvent(.leftMouseDown, at: start, in: window)))
        let focusChanged = await eventually {
            hosting.layoutSubtreeIfNeeded()
            return window.firstResponder !== responder
        }
        #expect(focusChanged)
        #expect(try image(hosting, in: before) == neutralDivider)
        // The divider takes the keyboard without the system focus ring, which would draw a blue strip around it.
        #expect(window.firstResponder === handle)
        #expect(handle.focusRingType == .none)

        window.sendEvent(
            try #require(mouseEvent(.leftMouseDragged, at: NSPoint(x: start.x + 10, y: start.y), in: window)))
        _ = await eventually {
            hosting.layoutSubtreeIfNeeded()
            guard let current = pointer(in: hosting) else { return false }
            return abs(current.convert(current.bounds, to: hosting).minX - before.minX - 10) < 0.5
        }
        window.sendEvent(
            try #require(mouseEvent(.leftMouseDragged, at: NSPoint(x: start.x + 40, y: start.y), in: window)))
        window.sendEvent(try #require(mouseEvent(.leftMouseUp, at: NSPoint(x: start.x + 40, y: start.y), in: window)))
        hosting.layoutSubtreeIfNeeded()

        let current = try #require(pointer(in: hosting))
        let after = current.convert(current.bounds, to: hosting)
        #expect(abs(after.minX - before.minX - 40) < 0.5)

        // The arrow keys still resize the focused divider.
        window.sendEvent(try #require(arrowKey(.leftArrow, in: window)))
        let narrowed = await eventually {
            hosting.layoutSubtreeIfNeeded()
            guard let current = pointer(in: hosting) else { return false }
            return current.convert(current.bounds, to: hosting).minX < after.minX - 1
        }
        #expect(narrowed)
    }

    /// The leftmost divider: the sidebar's.
    private func pointer(in view: NSView) -> NSView? { pointers(in: view).first }

    /// Every resize divider, left to right.
    private func pointers(in view: NSView) -> [NSView] {
        func collect(_ node: NSView) -> [NSView] {
            String(describing: type(of: node)) == "ResizePointerView" ? [node] : node.subviews.flatMap(collect)
        }
        return collect(view).sorted { $0.convert($0.bounds, to: view).minX < $1.convert($1.bounds, to: view).minX }
    }

    private func image(_ view: NSView, in rect: NSRect) throws -> Data {
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: image)
        return try #require(image.representation(using: .png, properties: [:]))
    }

    private func arrowKey(_ key: NSEvent.SpecialKey, in window: NSWindow) -> NSEvent? {
        let character = String(Character(Unicode.Scalar(key.rawValue)!))
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: key == .leftArrow ? 123 : 124)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: clicks, pressure: 1)
    }

    @Test("Dragging the thread pane divider widens the pane, keeps the conversation usable, and remembers the width")
    func paneDivider() async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.enterPreview()
        let saved = ["layout.sidebarWidth", "layout.paneWidth"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        UserDefaults.standard.set(280, forKey: "layout.sidebarWidth")
        UserDefaults.standard.removeObject(forKey: "layout.paneWidth")
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        let hosting = NSHostingView(rootView: RootView(matrix: matrix).environmentObject(AppearanceStore()))
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1_440, height: 900),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        func frames() -> [NSRect] {
            hosting.layoutSubtreeIfNeeded()
            return pointers(in: hosting).map { $0.convert($0.bounds, to: hosting) }
        }
        func drag(by distance: CGFloat) throws {
            let start = try #require(frames().last.map { NSPoint(x: $0.midX, y: $0.midY) })
            let end = NSPoint(x: start.x + distance, y: start.y)
            window.sendEvent(try #require(mouseEvent(.leftMouseDown, at: start, in: window)))
            window.sendEvent(
                try #require(
                    mouseEvent(.leftMouseDragged, at: NSPoint(x: start.x + distance / 2, y: start.y), in: window)))
            window.sendEvent(try #require(mouseEvent(.leftMouseDragged, at: end, in: window)))
            window.sendEvent(try #require(mouseEvent(.leftMouseUp, at: end, in: window)))
        }

        _ = await eventually { frames().count == 1 }
        // A thread, from a message's own context menu, opens the pane.
        func messages() -> [NSTextView] {
            func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
            return all(hosting).compactMap { $0 as? NSTextView }.filter { !$0.isEditable && !$0.string.isEmpty }
        }
        _ = await eventually { !messages().isEmpty }
        let click = try #require(mouseEvent(.rightMouseDown, at: .zero, in: window))
        let menu = try #require(messages().last?.menu(for: click))
        let thread = try #require(menu.items.first { $0.identifier?.rawValue == "thread" })
        _ = thread.target?.perform(thread.action, with: thread)
        _ = await eventually { frames().count == 2 }
        let before = try #require(frames().last)
        #expect(frames().count == 2)

        window.isMovableByWindowBackground = true
        let hit = try #require(hosting.hitTest(NSPoint(x: before.midX, y: before.midY)))
        #expect(!hit.mouseDownCanMoveWindow)

        try drag(by: -40)
        _ = await eventually { abs((frames().last?.minX ?? 0) - before.minX + 40) < 0.5 }
        #expect(abs(try #require(frames().last).minX - before.minX + 40) < 0.5)
        #expect(UserDefaults.standard.double(forKey: "layout.paneWidth") == 420)

        // Far past the limit, the conversation between the two dividers keeps its 360 pt.
        try drag(by: -2_000)
        _ = await eventually { (frames().last?.minX ?? 0) < before.minX - 100 }
        let squeezed = frames()
        #expect(squeezed[1].minX - squeezed[0].maxX >= 360)

        let reset = try #require(frames().last.map { NSPoint(x: $0.midX, y: $0.midY) })
        window.sendEvent(try #require(mouseEvent(.leftMouseDown, at: reset, in: window, clicks: 2)))
        window.sendEvent(try #require(mouseEvent(.leftMouseUp, at: reset, in: window, clicks: 2)))
        _ = await eventually { abs((frames().last?.minX ?? 0) - before.minX) < 0.5 }
        #expect(abs(try #require(frames().last).minX - before.minX) < 0.5)
    }
}
