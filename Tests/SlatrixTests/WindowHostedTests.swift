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
            hosting = NSHostingView(rootView: Self.root(matrix, appearance, zoom: zoom))
            // Titled, as `.hiddenTitleBar` sets up the app's window, so it has the window buttons.
            window = offscreenWindow(
                NSSize(width: 1_440, height: 900),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = hosting
            window.orderFrontRegardless()
        }

        static func root(_ matrix: MatrixService, _ appearance: AppearanceStore, zoom: Double) -> AnyView {
            AnyView(RootView(matrix: matrix).environmentObject(appearance).environment(\.metrics, Metrics(zoom: zoom)))
        }

        /// As ⌘= and ⌘- change it, with the window open.
        func zoom(_ zoom: Double) { hosting.rootView = Self.root(matrix, appearance, zoom: zoom) }

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

        /// The red, green and blue of every pixel in `rect`, a frame in the window, as drawn.
        func pixels(in rect: CGRect) -> [CGFloat] {
            hosting.layoutSubtreeIfNeeded()
            guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return [] }
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            let scale = CGFloat(image.pixelsWide) / hosting.bounds.width
            // Bitmap rows run down from the top; window frames up from the bottom.
            let rows =
                Int((hosting.bounds.height - rect.maxY) * scale)..<Int((hosting.bounds.height - rect.minY) * scale)
            return rows.flatMap { y in
                (Int(rect.minX * scale)..<Int(rect.maxX * scale)).flatMap { x in
                    image.colorAt(x: x, y: y).map { [$0.redComponent, $0.greenComponent, $0.blueComponent] } ?? []
                }
            }
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
        var searchField: NSView? {
            shown().first { ($0 as? NSTextField)?.placeholderString?.hasPrefix("Search ") == true }
        }
        var searchFieldShown: Bool { searchField != nil }

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

        /// The channel header's tabs, left to right: the runs of ink in the row above the timeline, where the gap
        /// between two tabs is wider than any inside one.
        func tabs() throws -> [CGRect] {
            let timeline = try timeline()
            // Past the divider, and short of the underline and the row's edges.
            let row = CGRect(x: timeline.minX, y: timeline.maxY + 6, width: timeline.width / 2, height: 30)
            hosting.layoutSubtreeIfNeeded()
            let image = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            let scale = CGFloat(image.pixelsWide) / hosting.bounds.width
            let rows = Int((hosting.bounds.height - row.maxY) * scale)..<Int((hosting.bounds.height - row.minY) * scale)
            let paper = try #require(image.colorAt(x: Int(row.minX * scale) + 1, y: rows.lowerBound))
            var runs: [ClosedRange<CGFloat>] = []
            for x in Int(row.minX * scale)..<Int(row.maxX * scale) {
                let inked = rows.contains { y in
                    image.colorAt(x: x, y: y).map {
                        abs($0.redComponent - paper.redComponent) + abs($0.greenComponent - paper.greenComponent)
                            + abs($0.blueComponent - paper.blueComponent) > 0.3
                    } ?? false
                }
                guard inked else { continue }
                let point = CGFloat(x) / scale
                if let last = runs.last, point - last.upperBound < 12 {
                    runs[runs.count - 1] = last.lowerBound...point
                } else {
                    runs.append(point...point)
                }
            }
            return runs.map {
                CGRect(x: $0.lowerBound, y: row.minY, width: $0.upperBound - $0.lowerBound, height: row.height)
            }
        }

        func click(_ frame: CGRect) async throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                await drainMainActor()
                window.sendEvent(
                    try #require(
                        NSEvent.mouseEvent(
                            with: type, location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
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

    // capability: conversation.members
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

    // capability: conversation.files
    @Test("Files & links shows the channel's files under its header, and Messages brings its messages back")
    func filesTab() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        func filesShown() -> Bool {
            harness.shown().contains { ($0 as? NSTextField)?.placeholderString == "Search files and links" }
        }

        // Messages, Pins, then Files & links.
        let tabs = try harness.tabs()
        try #require(tabs.count == 3, "\(tabs)")
        try await harness.click(tabs[2])
        #expect(await eventually { filesShown() })
        try await harness.click(tabs[0])
        #expect(await eventually { !filesShown() && (try? harness.newest().window) != nil })
    }

    // capability: message.save
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

    // capability: message.save.sync
    @Test("A message saved on another device joins Later after its sync, and the card already there stays as it was")
    func laterFromAnotherDevice() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        func message(_ id: String, _ body: String) -> ChatMessage {
            ChatMessage(
                id: id, roomID: "!later:example.org", senderID: "@ana:example.org", senderName: "Ana", body: body,
                timestamp: Date(timeIntervalSince1970: 1_761_955_000))
        }
        let older = message("$older", "Budget is in the doc")
        let newer = message("$newer", "Ship it on Thursday")
        // Where the preview reads a saved message from.
        harness.matrix.threadMessages = [older, newer]
        let entry = { (id: String, ts: Int) in #"{"room_id":"!later:example.org","event_id":"\#(id)","ts":\#(ts)}"# }
        let client = LaterClient(server: #"{"saved":[\#(entry("$older", 1_761_955_200_000))],"removed":[]}"#)
        harness.matrix.savedMessages.attach(client, accountID: "preview.you")
        harness.menu("later")
        func card(_ message: ChatMessage) -> NSView? {
            harness.shown().first { ($0 as? MessageTextView)?.string == message.body }
        }
        #expect(await eventually { card(older) != nil })
        let shown = try #require(card(older))

        client.sync(
            #"{"saved":[\#(entry("$newer", 1_761_955_300_000)),\#(entry("$older", 1_761_955_200_000))],"removed":[]}"#)
        #expect(await eventually { card(newer) != nil })
        #expect(card(older) === shown)
    }

    // capability: app.offline-banner
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

    // capability: channel.read-only
    @Test("A channel you may not post in shows a line in place of both composers, with the timeline still")
    func cannotPost() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        let before = try harness.timeline()
        let index = try #require(harness.matrix.rooms.firstIndex { $0.id == harness.matrix.selectedRoomID })
        harness.matrix.rooms[index].canPostMessages = false
        func editors() -> Int { harness.shown().filter { ($0 as? NSTextView)?.isEditable == true }.count }
        let canvas = try #require(NSColor(harness.appearance.colors.canvas).usingColorSpace(.sRGB))
        // The line is centered, where an empty composer shows no text: ink across the middle of a pane's bottom.
        func lineShown(_ pane: CGRect, from bottom: CGFloat) -> Bool {
            harness.longestRun(in: CGRect(x: pane.midX - 60, y: bottom, width: 120, height: 120)) {
                abs($0.redComponent - canvas.redComponent) + abs($0.greenComponent - canvas.greenComponent)
                    + abs($0.blueComponent - canvas.blueComponent) > 0.3
            } > 0
        }
        #expect(await eventually { editors() == 0 && lineShown(before, from: before.minY - 120) })
        #expect(try harness.timeline() == before)

        try harness.openThread()
        #expect(await eventually { harness.shown().compactMap { $0 as? UploadDropView }.count == 2 })
        let pane = try #require(
            harness.shown().compactMap { $0 as? UploadDropView }.map { $0.convert($0.bounds, to: nil) }
                .max { $0.minX < $1.minX })
        #expect(editors() == 0)
        #expect(lineShown(pane, from: pane.minY))
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

    // capability: app.narrow-window
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

    @Test(
        "The window buttons hold the title bar's midline on every frame of a resize from any edge, and through a zoom",
        arguments: [1, 1.5])
    func windowButtonsCentered(zoom: Double) async throws {
        let harness = Harness(zoom: zoom)
        defer { harness.close() }
        #expect(await harness.settle())
        let close = try #require(harness.window.standardWindowButton(.closeButton))
        // The search field is centered in the title bar.
        func offset(_ search: NSView?) -> CGFloat {
            guard let search else { return .infinity }
            return close.convert(close.bounds, to: nil).midY - search.convert(search.bounds, to: nil).midY
        }
        // Titled, the window still never reaches a screen.
        func offscreen() -> Bool { !NSScreen.screens.contains { $0.frame.intersects(harness.window.frame) } }
        #expect(offscreen())
        #expect(await eventually { abs(offset(harness.searchField)) <= 1 }, "\(offset(harness.searchField))")

        // A live resize sets the window's frame and draws it in one go, so each frame is checked as it is drawn,
        // with no turn of the run loop between, and against the field found before, since finding it lays the window
        // out. Dragging the left edge changes the width, the top edge the height, and the top left corner both. Only
        // the size reaches the views, so the right and bottom edges and the other corners take the same path.
        let search = try #require(harness.searchField)
        for (edge, widthChange, heightChange) in [("left", -20.0, 0.0), ("top", 0, -20), ("corner", -20, -20)] {
            for step in 1...3 {
                let frame = harness.window.frame
                harness.window.setFrame(
                    NSRect(
                        x: frame.minX - widthChange, y: frame.minY, width: frame.width + widthChange,
                        height: frame.height + heightChange), display: true)
                #expect(abs(offset(search)) <= 1, "\(edge), step \(step): \(offset(search))")
            }
        }
        #expect(offscreen())

        // The buttons' container now reaches down the whole bar, and a click on the field still lands in it.
        let field = search.convert(search.bounds, to: nil)
        let hit = harness.window.contentView?.superview?.hitTest(NSPoint(x: field.midX, y: field.minY + 1))
        #expect(hit.map { $0 === search || $0.isDescendant(of: search) } == true)

        // Zooming in or out changes the bar's height under the buttons.
        harness.zoom(zoom == 1 ? 1.5 : 1)
        #expect(await eventually { abs(offset(harness.searchField)) <= 1 }, "\(offset(harness.searchField))")
    }

    @Test("A modal dims the window below the title bar, which looks the same and takes no clicks", arguments: [1, 1.5])
    func modalLeavesTitleBar(zoom: Double) async throws {
        let harness = Harness(zoom: zoom)
        defer { harness.close() }
        #expect(await harness.settle())
        let search = try #require(harness.searchField)
        let field = search.convert(search.bounds, to: nil)
        // The title bar, centered on its search field: under the window buttons, and from the field to the window's
        // right edge, past Sign in and help. The AppKit controls between draw as the offscreen window's key state
        // has them, which a modal changes. A point short of the bar's bottom edge, which can fall inside a pixel.
        let height = 2 * (harness.hosting.bounds.height - field.midY) - 1
        let top = harness.hosting.bounds.height - height
        let zoomButton = try #require(harness.window.standardWindowButton(.zoomButton))
        let buttons = zoomButton.convert(zoomButton.bounds, to: nil).maxX
        let stretches = [
            CGRect(x: 0, y: top, width: buttons, height: height),
            CGRect(x: field.maxX, y: top, width: harness.hosting.bounds.width - field.maxX, height: height),
        ]
        let before = stretches.map(harness.pixels)
        harness.menu("preferences")
        // Preferences opens on Appearance, with its profile photos switch.
        #expect(await eventually { harness.shown().contains { $0 is NSSwitch } })

        // The scrim is in once the window's frame color along its bottom edge, under the panel, is dimmed.
        let frame = try #require(NSColor(harness.appearance.colors.frame).usingColorSpace(.sRGB))
        let edge = CGRect(x: 0, y: 0, width: harness.hosting.bounds.width, height: 2)
        #expect(
            await eventually {
                harness.longestRun(in: edge) {
                    abs($0.redComponent - frame.redComponent) + abs($0.greenComponent - frame.greenComponent)
                        + abs($0.blueComponent - frame.blueComponent) < 0.03
                } == 0
            })
        // Within a step or two of 255: antialiased edges at 150% land a shade apart from one drawing to the next.
        for (shown, was) in zip(stretches.map(harness.pixels), before) {
            #expect(shown.count == was.count && zip(shown, was).allSatisfy { abs($0 - $1) < 0.01 })
        }
        let hit = harness.hosting.hitTest(NSPoint(x: field.midX, y: field.midY))
        #expect(hit.map { $0 !== search && !$0.isDescendant(of: search) } ?? true)
    }
}
