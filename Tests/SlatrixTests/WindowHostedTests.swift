import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// The whole window in a real offscreen window, with a busy conversation open; needs an awake display. Budgets sit
/// near seven times an M4 Pro debug run, as in `PerformanceBudgetTests`.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct WindowHostedTests {
    @MainActor private final class Harness {
        let matrix = MatrixService()
        let appearance = AppearanceStore()
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
        let messages: [ChatMessage]

        init(zoom: Double = 1) {
            _ = NSApplication.shared
            matrix.enterPreview()
            messages = busyConversation(1_000, roomID: matrix.selectedRoomID!, tag: UUID().uuidString)
            matrix.messages = messages
            // A busy account: the open workspace lists nearly 300 conversations.
            matrix.rooms += (0..<280).map {
                ChatRoom(
                    id: "!busy\($0):example.org", name: "Busy \($0)", unread: $0 % 3, spaceIDs: ["preview.workspace"])
            }
            hosting = NSHostingView(
                rootView: AnyView(
                    RootView(matrix: matrix).environmentObject(appearance)
                        .environment(\.metrics, Metrics(zoom: zoom))))
            window = offscreenWindow(NSSize(width: 1_440, height: 900))
            window.contentView = hosting
            window.orderFrontRegardless()
        }

        func close() {
            window.contentView = nil
            window.close()
        }

        /// Until the conversation's newest message is on screen.
        func settle() async -> Bool {
            await eventually(timeout: .seconds(20)) {
                hosting.layoutSubtreeIfNeeded()
                return Self.views(in: hosting).contains {
                    ($0 as? MessageTextView)?.string == messages.last?.body && $0.window != nil
                }
            }
        }

        /// Main-thread time for `count` changes, each laid out and drawn as its frame would be.
        func mainThreadTime(_ count: Int, _ change: (Int) -> Void) -> Duration {
            let start = threadCPUTime()
            for index in 0..<count {
                change(index)
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
            }
            return threadCPUTime() - start
        }

        static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

        /// The newest message's text, where the window shows it.
        func newest() throws -> NSView {
            try #require(Self.views(in: hosting).first { ($0 as? MessageTextView)?.string == messages.last?.body })
        }

        /// The timeline's frame in the window.
        func timeline() throws -> CGRect {
            let scroll = try #require(try newest().enclosingScrollView)
            return scroll.convert(scroll.bounds, to: nil)
        }

        /// The longest row of pixels in `band`, a frame in the window, that pass `test`, in points.
        func longestRun(in band: CGRect, _ test: (NSColor) -> Bool) -> CGFloat {
            hosting.layoutSubtreeIfNeeded()
            guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 0 }
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            let scale = CGFloat(image.pixelsWide) / hosting.bounds.width
            var longest = 0
            // Bitmap rows run down from the top; window frames up from the bottom.
            let rows =
                Int((hosting.bounds.height - band.maxY) * scale)..<Int((hosting.bounds.height - band.minY) * scale)
            for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 2) {
                var run = 0
                for x in Int(band.minX * scale)..<Int(band.maxX * scale) {
                    // As drawn, unconverted: the bitmap already holds the theme's sRGB values.
                    if let pixel = image.colorAt(x: x, y: y), test(pixel) {
                        run += 1
                        longest = max(longest, run)
                    } else {
                        run = 0
                    }
                }
            }
            return CGFloat(longest) / scale
        }

        /// Laid out, so what it finds is what the window shows.
        func shown() -> [NSView] {
            hosting.layoutSubtreeIfNeeded()
            return Self.views(in: hosting).filter { $0.window != nil }
        }
        /// The sidebar's and an open pane's dividers.
        var dividers: Int { shown().filter { String(describing: type(of: $0)) == "ResizePointerView" }.count }
        var sidebarShown: Bool {
            shown().contains { ($0 as? NSTextField)?.placeholderString == "Find a conversation…" }
        }
        /// The conversation's left edge: past the rail while it shows, at the window's inset once it folds away.
        var conversationLeft: CGFloat? {
            shown().compactMap { $0 as? UploadDropView }.map { $0.convert($0.bounds, to: nil).minX }.min()
        }
        var searchFieldShown: Bool {
            shown().contains { ($0 as? NSTextField)?.placeholderString?.hasPrefix("Search ") == true }
        }

        /// Through a message's own context menu, the item a right-click shows.
        func openThread() throws {
            let message = try #require(
                shown().compactMap { $0 as? MessageTextView }.last { !$0.isEditable && !$0.string.isEmpty })
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let item = try #require(message.menu(for: event)?.items.first { $0.identifier?.rawValue == "thread" })
            _ = item.target?.perform(item.action, with: item)
        }

        func resize(_ width: CGFloat) { window.setContentSize(NSSize(width: width, height: 900)) }

        func menu(_ action: String) {
            NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": action])
        }
    }

    @Test(
        "100 room-list updates with a 1,000-message conversation open hold the main thread within budget",
        .tags(.budget), .enabled(if: budgetsEnabled))
    func roomListBudget() async {
        let time = await fastest {
            let harness = Harness()
            defer { harness.close() }
            #expect(await harness.settle())
            // The open conversation's unread count changes with every message that arrives in it, too.
            let open = harness.matrix.rooms.firstIndex { $0.id == harness.matrix.selectedRoomID }!
            let other = harness.matrix.rooms.firstIndex { $0.id != harness.matrix.selectedRoomID }!
            return harness.mainThreadTime(100) {
                harness.matrix.rooms[$0.isMultiple(of: 2) ? open : other].unread = $0 % 7 + 1
            }
        }
        #expect(time < .seconds(7), "\(time)")
    }

    @Test(
        "100 typing changes with a 1,000-message conversation open hold the main thread within budget",
        .tags(.budget), .enabled(if: budgetsEnabled))
    func typingBudget() async {
        let time = await fastest {
            let harness = Harness()
            defer { harness.close() }
            #expect(await harness.settle())
            return harness.mainThreadTime(100) { harness.matrix.typingUsers = $0.isMultiple(of: 2) ? ["Alex"] : [] }
        }
        #expect(time < .milliseconds(250), "\(time)")
    }

    @Test(
        "100 keystrokes in the composer with a 1,000-message conversation open hold the main thread within budget",
        .tags(.budget), .enabled(if: budgetsEnabled))
    func keystrokeBudget() async throws {
        let time = try await fastest {
            let harness = Harness()
            defer { harness.close() }
            #expect(await harness.settle())
            let editor = try #require(
                Harness.views(in: harness.hosting).compactMap { $0 as? NSTextView }.first { $0.isEditable })
            return harness.mainThreadTime(100) { _ in editor.insertText("a", replacementRange: editor.selectedRange()) }
        }
        #expect(time < .milliseconds(1_700), "\(time)")
    }

    @Test("A click on the member facepile opens channel details on Members")
    func facepileOpensMembers() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        // The facepile sits just left of the header's ⋮, the rightmost menu in the window.
        let menu = try #require(
            Harness.views(in: harness.hosting).compactMap { $0 as? NSPopUpButton }.map {
                $0.convert($0.bounds, to: nil)
            }
            .max { $0.minX < $1.minX })
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            await drainMainActor()
            harness.window.sendEvent(
                try #require(
                    NSEvent.mouseEvent(
                        with: type, location: NSPoint(x: menu.minX - 20, y: menu.midY), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: harness.window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        #expect(
            await eventually {
                harness.hosting.layoutSubtreeIfNeeded()
                return Harness.views(in: harness.hosting).contains {
                    ($0 as? NSTextField)?.placeholderString == "Find members"
                }
            })
    }

    @Test("Saving a message for later confirms it with a toast above the composer that leaves on its own")
    func saveToast() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        let text = try #require(try harness.newest() as? MessageTextView)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let save = try #require(text.menu(for: event)?.items.first { $0.identifier?.rawValue == "save" })
        _ = save.target?.perform(save.action, with: save)

        // The toast is a solid bar of the tooltip color, wider than any glyph.
        let timeline = try harness.timeline()
        let bottom = CGRect(x: timeline.minX, y: timeline.minY, width: timeline.width, height: 120)
        let ink = try #require(NSColor(harness.appearance.colors.tooltip).usingColorSpace(.sRGB))
        func toastShown() -> Bool {
            harness.longestRun(in: bottom) {
                abs($0.redComponent - ink.redComponent) + abs($0.greenComponent - ink.greenComponent)
                    + abs($0.blueComponent - ink.blueComponent) < 0.1
            } > 120
        }
        #expect(await eventually { toastShown() })
        #expect(await eventually(timeout: .seconds(8)) { !toastShown() })
    }

    @Test("Going offline shows a banner over the conversation, and reconnecting clears it, with the timeline still")
    func offlineBanner() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        let newest = try harness.newest()
        let before = newest.convert(newest.bounds, to: nil)
        let timeline = try harness.timeline()
        let top = CGRect(x: timeline.minX, y: timeline.maxY - 60, width: timeline.width, height: 60)
        // The banner's warning tint: warm, across most of the pane.
        func bannerShown() -> Bool {
            harness.longestRun(in: top) { $0.redComponent - $0.blueComponent > 0.05 } > timeline.width / 2
        }

        harness.matrix.applyConnection(
            MatrixConnectionFeedback(
                state: .offline, isRetrying: false, canRetry: true,
                errorMessage: "You’re offline. Check your connection."
            ))
        #expect(await eventually { bannerShown() })
        // Within a point: the freshly opened timeline still settles by a fraction of one on its own.
        func still() -> Bool { abs(newest.convert(newest.bounds, to: nil).minY - before.minY) < 1 }
        #expect(still())

        harness.matrix.applyConnection(
            MatrixConnectionFeedback(state: .running, isRetrying: false, canRetry: false, errorMessage: nil))
        #expect(await eventually { !bannerShown() })
        #expect(still())
    }

    @Test("A conversation opened at an older message keeps its composer")
    func composerStaysAtOlderMessage() async {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        harness.matrix.focusedEventID = harness.messages[500].eventID
        await drainMainActor()
        harness.hosting.layoutSubtreeIfNeeded()
        #expect(
            Harness.views(in: harness.hosting).contains { ($0 as? NSTextView)?.isEditable == true && $0.window != nil })
    }

    @Test("At 150% zoom an open thread stays inside the panel")
    func paneFitsAtZoom() async throws {
        let harness = Harness(zoom: 1.5)
        defer { harness.close() }
        #expect(await harness.settle())
        try harness.openThread()
        // The rightmost drop target is the thread's, as wide as the pane; the panel ends 4 pt from the window's edge.
        let panelEdge = harness.window.frame.width - Metrics(zoom: 1.5).sp4
        #expect(
            await eventually {
                let targets = harness.shown().compactMap { $0 as? UploadDropView }
                return targets.count == 2 && targets.allSatisfy { $0.convert($0.bounds, to: nil).maxX <= panelEdge }
            })
    }

    @Test("Narrowing the window with a thread open folds the sidebar away first, then moves the thread over")
    func narrowing() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        try harness.openThread()
        #expect(await eventually { harness.dividers == 2 })

        // Only the thread's divider: conversation and thread side by side, the sidebar folded away.
        harness.resize(1_000)
        #expect(
            await eventually {
                harness.dividers == 1 && !harness.sidebarShown
                    && harness.conversationLeft ?? .infinity < Metrics().rail
            })
        harness.resize(700)
        #expect(await eventually { harness.dividers == 0 && harness.searchFieldShown })
        harness.resize(560)
        #expect(await eventually { !harness.searchFieldShown })

        // Closing the thread brings the sidebar back on its own.
        harness.resize(1_000)
        #expect(await eventually { harness.dividers == 1 && !harness.sidebarShown })
        harness.menu("toggle-pane")
        #expect(await eventually { harness.dividers == 1 && harness.sidebarShown })

        harness.resize(1_440)
        try harness.openThread()
        #expect(await eventually { harness.dividers == 2 && harness.sidebarShown && harness.searchFieldShown })
    }

    @Test("In a narrow window the sidebar opens as a drawer, and picking a conversation or Esc closes it")
    func drawer() async {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        harness.resize(700)
        #expect(await eventually { !harness.sidebarShown })

        harness.menu("toggle-sidebar")
        #expect(await eventually { harness.sidebarShown })
        harness.menu("next-conversation")
        #expect(await eventually { !harness.sidebarShown })

        harness.menu("toggle-sidebar")
        #expect(await eventually { harness.sidebarShown })
        // Esc, as the app's key monitor delivers it.
        harness.menu("mark-read")
        #expect(await eventually { !harness.sidebarShown })
    }

    @Test("Hiding the sidebar by hand at full width hides the rail too, and it comes back")
    func hiddenByHand() async {
        let key = "layout.sidebarHidden"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(false, forKey: key)
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        harness.menu("toggle-sidebar")
        #expect(await eventually { !harness.sidebarShown && harness.conversationLeft ?? .infinity < Metrics().rail })
        harness.menu("toggle-sidebar")
        #expect(await eventually { harness.sidebarShown && harness.dividers == 1 })
    }
}
