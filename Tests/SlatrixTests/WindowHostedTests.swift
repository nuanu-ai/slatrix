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
        let matrix = MatrixService.scratch()
        let appearance = AppearanceStore()
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
        let messages: [ChatMessage]

        init(zoom: Double = 1) {
            _ = NSApplication.shared
            // A pane dragged or a sidebar hidden in an earlier test stays so; every window here opens as it first would.
            for key in ["layout.paneWidth", "layout.sidebarHidden"] { UserDefaults.standard.removeObject(forKey: key) }
            // Start from a clean, deterministic appearance whatever another test or run left behind.
            appearance.theme = .neutral
            appearance.increaseContrast = false
            appearance.workspaceThemes = [:]
            appearance.density = .comfortable
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
            AnyView(RootView(scratch: matrix).environmentObject(appearance).environment(\.metrics, Metrics(zoom: zoom)))
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
                let views = Self.views(in: hosting)
                // The composer takes text once its draft has loaded.
                return views.contains { ($0 as? MessageTextView)?.string == messages.last?.body && $0.window != nil }
                    && views.contains { ($0 as? NSTextView)?.isEditable == true && !($0 is MessageTextView) }
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

        /// The composer floats over the timeline's bottom, which keeps its rows clear of it: where its glass starts.
        func composerTop() throws -> CGFloat {
            let scroll = try #require(try newest().enclosingScrollView)
            return try timeline().minY + scroll.contentInsets.bottom
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

        /// `CGWindowListCreateImageFromArray` captures the WindowServer-composited Metal/CoreAnimation window image,
        /// including SwiftUI backgrounds, gradients, and wallpaper tiles that CPU `cacheDisplay` skips on macOS 26.
        private static let windowsImage = unsafeBitCast(
            dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImageFromArray"),
            to: (@convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?).self)

        func compositedBitmap() -> NSBitmapImageRep? {
            hosting.layoutSubtreeIfNeeded()
            var ids = [UnsafeRawPointer(bitPattern: window.windowNumber)]
            let list = ids.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, $0.count, nil) }
            guard let cgImage = list.flatMap({ Self.windowsImage(.null, $0, 1 | 8)?.takeRetainedValue() }) else {
                return nil
            }
            return NSBitmapImageRep(cgImage: cgImage)
        }

        /// Samples a composited window pixel at AppKit window coordinates `(x, y)` in sRGB.
        func compositedColor(in bitmap: NSBitmapImageRep, at point: CGPoint) -> NSColor? {
            let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
            let px = Int((point.x * scale).rounded())
            let py = Int(((hosting.bounds.height - point.y) * scale).rounded())
            guard px >= 0, px < bitmap.pixelsWide, py >= 0, py < bitmap.pixelsHigh else { return nil }
            return bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB)
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
            SlatrixTests.sidebarShown(in: hosting)
        }
        /// The conversation's left edge: past the sidebar while it shows, at the window's edge once it folds away.
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

        /// A point in the toolbar's capsule of conversation buttons, which SwiftUI draws without views: `inset` from
        /// its trailing end, which sits a gap short of back and forward, and they of the search field, which ends at
        /// the toolbar's trailing margin.
        func toolbarCapsule(inset: CGFloat) -> CGRect {
            let m = Metrics()
            let history = 2 * m.iconButton + 2 * m.sp2
            let end =
                window.frame.width - m.conversationInset(thread: false) - m(RootView.searchWidth) - m.sp12 - history
                - m.sp12
            return CGRect(x: end - inset, y: window.frame.height - m.paneHeader / 2, width: 0, height: 0)
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

        func accessible(_ text: String) -> [AnyObject] { SlatrixTests.accessible(text, in: hosting) }
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

    @Test(
        "Dragging the thread's divider through 60 widths beside a 1,000-message conversation stays within budget",
        .tags(.budget), .enabled(if: budgetsEnabled))
    func paneResizeBudget() async throws {
        let time = try await fastest {
            let harness = Harness()
            defer { harness.close() }
            #expect(await harness.settle())
            try harness.openThread()
            #expect(await eventually { harness.dividers == 2 })
            let divider = try #require(
                harness.shown().filter { String(describing: type(of: $0)) == "ResizePointerView" }
                    .max { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
            let line = divider.convert(divider.bounds, to: nil).midX
            func send(_ type: NSEvent.EventType, _ x: CGFloat) throws {
                harness.window.sendEvent(
                    try #require(
                        NSEvent.mouseEvent(
                            with: type, location: NSPoint(x: x, y: 450), modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: harness.window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            try send(.leftMouseDown, line)
            defer { try? send(.leftMouseUp, line) }
            // Narrower and back, as a reader settles on a width.
            var farthest: CGFloat = 0
            let time = harness.mainThreadTime(60) { step in
                try? send(.leftMouseDragged, line + CGFloat(step < 30 ? step : 60 - step) * 4)
                farthest = max(farthest, divider.convert(divider.bounds, to: nil).midX - line)
            }
            // The drag reached the pane: it narrowed as far as the pointer went.
            #expect(farthest >= 100, "\(farthest)")
            return time
        }
        #expect(time < .seconds(2), "\(time)")
    }

    @Test(
        "Resizing the window through 60 widths, a 1,000-message conversation and a thread open, stays within budget",
        .tags(.budget), .enabled(if: budgetsEnabled))
    func windowResizeBudget() async throws {
        let time = try await fastest {
            let harness = Harness()
            defer { harness.close() }
            #expect(await harness.settle())
            try harness.openThread()
            #expect(await eventually { harness.dividers == 2 })
            return harness.mainThreadTime(60) { step in
                harness.resize(1_440 - CGFloat(step < 30 ? step : 60 - step) * 4)
            }
        }
        #expect(time < .seconds(2), "\(time)")
    }

    // capability: conversation.members
    @Test("A click on the member facepile opens channel details on Members")
    func facepileOpensMembers() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        // Members leads the toolbar's capsule, before pins, files and ⋯.
        try await harness.click(harness.toolbarCapsule(inset: 3 * Metrics().control + 10))
        #expect(
            await eventually {
                harness.hosting.layoutSubtreeIfNeeded()
                return Harness.views(in: harness.hosting).contains {
                    ($0 as? NSTextField)?.placeholderString == "Find members"
                }
            })
    }

    // capability: conversation.files
    @Test("Files and links in the toolbar opens the channel's files beside its messages, closing like a thread")
    func filesTab() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        func filesShown() -> Bool {
            harness.shown().contains { ($0 as? NSTextField)?.placeholderString == "Search files and links" }
        }

        // Files sits just left of the capsule's ⋯.
        let files = harness.toolbarCapsule(inset: 1.5 * Metrics().control)
        try await harness.click(files)
        #expect(await eventually { filesShown() && harness.dividers == 2 })
        // Beside the conversation, which keeps its messages.
        #expect((try? harness.newest().window) != nil)
        harness.menu("toggle-pane")
        #expect(await eventually { !filesShown() && harness.dividers == 1 })
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
        let bottom = CGRect(x: timeline.minX, y: try harness.composerTop(), width: timeline.width, height: 120)
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

    // capability: home.browse-channels
    @Test("Browse channels opens as a page in place of the conversation, and picking a channel brings it back")
    func browseChannelsPage() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        func search() -> Bool {
            harness.shown().contains { ($0 as? NSTextField)?.placeholderString == "Search by name or topic" }
        }
        func editors() -> Int { harness.shown().filter { ($0 as? NSTextView)?.isEditable == true }.count }
        #expect(!search() && editors() > 0)

        harness.menu("browse-channels")
        #expect(await eventually { search() && editors() == 0 })
        #expect(harness.sidebarShown)

        harness.menu("next-conversation")
        #expect(await eventually { !search() && editors() > 0 })
    }

    @Test("A save from another device lands above a scrolled Later without moving the cards in view")
    func laterKeepsItsPlace() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        let messages = (1...21).map {
            ChatMessage(
                id: "$later\($0)", roomID: "!later:example.org", senderID: "@ana:example.org", senderName: "Ana",
                body: "Saved message \($0)", timestamp: Date(timeIntervalSince1970: 1_761_955_000))
        }
        // Where the preview reads a saved message from.
        harness.matrix.threadMessages = messages
        let entry = { (index: Int) in
            #"{"room_id":"!later:example.org","event_id":"$later\#(index)","ts":\#(1_761_955_200_000 + index)}"#
        }
        let client = LaterClient(server: #"{"saved":[\#((1...20).map(entry).joined(separator: ","))],"removed":[]}"#)
        harness.matrix.savedMessages.attach(client, accountID: "preview.you")
        harness.menu("later")
        func card(_ index: Int) -> NSView? {
            harness.shown().first { ($0 as? MessageTextView)?.string == "Saved message \(index)" }
        }
        #expect(await eventually { card(20) != nil })
        let scroll = try #require(card(20)?.enclosingScrollView)
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 500))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.minY > 0)
        #expect(await eventually { card(12) != nil })
        let shown = try #require(card(12))
        let before = shown.convert(shown.bounds, to: nil)

        client.sync(#"{"saved":[\#((1...21).map(entry).joined(separator: ","))],"removed":[]}"#)
        #expect(await eventually { harness.matrix.savedMessages.list.saved.count == 21 })
        await drainMainActor()
        harness.hosting.layoutSubtreeIfNeeded()
        #expect(abs(shown.convert(shown.bounds, to: nil).minY - before.minY) < 1)
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
        // Under the header, which floats over the timeline's top.
        let top = CGRect(
            x: timeline.minX, y: timeline.maxY - Metrics().paneHeader - 60, width: timeline.width, height: 60)
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

    @Test("The composer sits a margin above the window's bottom edge, with no room held for typing names")
    func composerMargin() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        let views = Harness.views(in: harness.hosting).filter { $0.window != nil }
        let field = try #require(views.first { ($0 as? NSTextView)?.isEditable == true })
        let composer = field.convert(field.bounds, to: nil)
        // The space under the composer's text is what is above it in its card, plus the card's margin.
        let above = try harness.composerTop() - composer.maxY
        #expect(composer.minY - above <= Metrics(zoom: 1).sp16)
    }

    @Test("Messages scroll under the header and the composer, and the newest sits right above the composer as it grows")
    func timelineUnderGlass() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        let timeline = try harness.timeline()
        // The timeline runs under the header to the window's top and under the composer to its bottom.
        #expect(timeline.maxY == harness.hosting.bounds.maxY && timeline.minY == harness.hosting.bounds.minY)
        let editor = try #require(harness.shown().first { ($0 as? NSTextView)?.isEditable == true } as? NSTextView)
        let newest = try harness.newest()
        func gap() -> CGFloat {
            newest.convert(newest.bounds, to: nil).minY - editor.convert(editor.bounds, to: nil).maxY
        }
        let before = gap()
        #expect(before > 0)
        let height = editor.frame.height
        editor.insertText("A draft\nthat runs\nover three lines", replacementRange: editor.selectedRange())
        #expect(
            await eventually {
                harness.hosting.layoutSubtreeIfNeeded()
                return editor.frame.height > height
            })
        await drainMainActor()
        harness.hosting.layoutSubtreeIfNeeded()
        #expect(abs(gap() - before) < 1, "\(gap()) from \(before)")
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
        #expect(await eventually { editors() == 0 && lineShown(before, from: before.minY) })
        #expect(try harness.timeline() == before)

        try harness.openThread()
        #expect(await eventually { harness.shown().compactMap { $0 as? UploadDropView }.count == 2 })
        let pane = try #require(
            harness.shown().compactMap { $0 as? UploadDropView }.map { $0.convert($0.bounds, to: nil) }
                .max { $0.minX < $1.minX })
        #expect(editors() == 0)
        #expect(lineShown(pane, from: pane.minY))
    }

    // capability: app.themes
    @Test(
        "Switching across all six themes keeps sidebar, search bar, window buttons and conversation geometry invariant",
        arguments: [false, true])
    func zeroLayoutShiftAcrossThemes(dark: Bool) async throws {
        let saved = [
            "appearance.mode", "appearance.theme", "appearance.chatWallpaper", "appearance.increaseContrast",
            "appearance.workspaceThemes",
        ].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        let harness = Harness()
        defer { harness.close() }
        harness.appearance.mode = dark ? .dark : .light
        harness.appearance.systemIsDark = dark
        harness.appearance.theme = .glass
        harness.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        #expect(await harness.settle())

        VoiceOver.listen()
        defer { VoiceOver.done() }

        func hideSidebarFrame() -> CGRect? {
            harness.accessible("Hide sidebar").first?.accessibilityFrame?()
        }
        #expect(await eventually { hideSidebarFrame() != nil })

        let baseTimeline = try harness.timeline()
        let baseConversationLeft = try #require(harness.conversationLeft)
        let baseSearch = try #require(harness.searchField).convert(try #require(harness.searchField).bounds, to: nil)
        let closeButton = try #require(harness.window.standardWindowButton(.closeButton))
        let baseClose = closeButton.convert(closeButton.bounds, to: nil)
        let baseHideSidebar = try #require(hideSidebarFrame())

        // Conversation always runs edge-to-edge from top to bottom of the window.
        #expect(baseTimeline.maxY == harness.hosting.bounds.maxY)
        #expect(baseTimeline.minY == harness.hosting.bounds.minY)

        for theme in ColorTheme.allCases {
            harness.appearance.theme = theme
            await drainMainActor()
            harness.hosting.layoutSubtreeIfNeeded()
            let timeline = try harness.timeline()
            let conversationLeft = try #require(harness.conversationLeft)
            let search = try #require(harness.searchField).convert(try #require(harness.searchField).bounds, to: nil)
            let close = closeButton.convert(closeButton.bounds, to: nil)
            let hideSidebar = try #require(hideSidebarFrame())
            #expect(abs(timeline.minX - baseTimeline.minX) < 0.5, "\(theme) timeline minX shifted")
            #expect(abs(timeline.minY - baseTimeline.minY) < 0.5, "\(theme) timeline minY shifted")
            #expect(abs(timeline.width - baseTimeline.width) < 0.5, "\(theme) timeline width shifted")
            #expect(abs(timeline.height - baseTimeline.height) < 0.5, "\(theme) timeline height shifted")
            #expect(abs(conversationLeft - baseConversationLeft) < 0.5, "\(theme) conversationLeft shifted")
            #expect(abs(search.minY - baseSearch.minY) < 0.5, "\(theme) search minY shifted")
            #expect(abs(search.height - baseSearch.height) < 0.5, "\(theme) search height shifted")
            #expect(abs(close.minY - baseClose.minY) < 0.5, "\(theme) window buttons shifted")
            #expect(abs(hideSidebar.minY - baseHideSidebar.minY) < 0.5, "\(theme) sidebar header shifted")

            // Variant B: the margin and resize gap around the floating sidebar match the window canvas,
            // while colored themes paint their distinct color inside the floating sidebar panel.
            if theme.isColored {
                let handle = Metrics()(SidebarLayout.handleWidth)
                let marginPoint = CGPoint(x: 2, y: 180)
                let gapPoint = CGPoint(x: conversationLeft - handle / 2, y: 180)
                // Pure open canvas in the trailing area of the conversation pane (same display profile as margin/gap).
                let canvasPoint = CGPoint(x: timeline.maxX - 40, y: 180)
                // Top center of the floating sidebar header: between the window buttons and Hide sidebar, pure fill.
                let sidebarPoint = CGPoint(x: 150, y: harness.hosting.bounds.height - 26)
                func colorDistance(_ first: NSColor, _ second: NSColor) -> CGFloat {
                    abs(first.redComponent - second.redComponent)
                        + abs(first.greenComponent - second.greenComponent)
                        + abs(first.blueComponent - second.blueComponent)
                }
                var lastDiag = ""
                #expect(
                    await eventually {
                        guard let bitmap = harness.compositedBitmap(),
                            let canvasColor = harness.compositedColor(in: bitmap, at: canvasPoint),
                            let marginColor = harness.compositedColor(in: bitmap, at: marginPoint),
                            let gapColor = harness.compositedColor(in: bitmap, at: gapPoint),
                            let sidebarColor = harness.compositedColor(in: bitmap, at: sidebarPoint)
                        else { return false }
                        let marginDist = colorDistance(marginColor, canvasColor)
                        let gapDist = colorDistance(gapColor, canvasColor)
                        let sidebarDist = colorDistance(sidebarColor, canvasColor)
                        lastDiag = String(
                            format: "marginDist=%.3f gapDist=%.3f sidebarDist=%.3f", marginDist, gapDist, sidebarDist)
                        return marginDist < 0.03 && gapDist < 0.03 && sidebarDist > 0.12
                    }, "\(theme) dark=\(dark): floating colored sidebar should sit on window canvas (\(lastDiag))")
            }
        }
    }

    // capability: app.themes
    @Test(
        "Chat wallpaper toggles doodles behind the timeline independently on all six themes",
        arguments: ColorTheme.allCases)
    func chatWallpaperToggleWorksOnAnyTheme(theme: ColorTheme) async throws {
        let saved = [
            "appearance.mode", "appearance.theme", "appearance.chatWallpaper", "appearance.increaseContrast",
            "appearance.workspaceThemes",
        ].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        let harness = Harness()
        defer { harness.close() }
        // Keep a single short message so the trailing side of the wide timeline is pure open canvas.
        harness.matrix.messages = [harness.messages.last!]
        harness.appearance.mode = .dark
        harness.appearance.systemIsDark = true
        harness.appearance.theme = theme
        harness.appearance.chatWallpaper = false
        harness.window.appearance = NSAppearance(named: .darkAqua)
        #expect(await harness.settle())

        let timeline = try harness.timeline()
        let patch = CGRect(x: timeline.maxX - 300, y: 260, width: 240, height: 240)

        // Compare against a sampled baseline color inside the same composited frame to stay independent of display ICC
        // color profiles. Pure canvas is completely uniform; doodle strokes create pixels slightly brighter than base.
        func doodlePixelCount() -> Int? {
            guard let bitmap = harness.compositedBitmap() else { return nil }
            var samples: [NSColor] = []
            samples.reserveCapacity(6_400)
            for y in stride(from: patch.minY, to: patch.maxY, by: 3) {
                for x in stride(from: patch.minX, to: patch.maxX, by: 3) {
                    if let pixel = harness.compositedColor(in: bitmap, at: CGPoint(x: x, y: y)) {
                        samples.append(pixel)
                    }
                }
            }
            guard
                let base = samples.min(by: {
                    ($0.redComponent + $0.greenComponent + $0.blueComponent)
                        < ($1.redComponent + $1.greenComponent + $1.blueComponent)
                })
            else { return nil }
            return samples.filter { pixel in
                abs(pixel.redComponent - base.redComponent)
                    + abs(pixel.greenComponent - base.greenComponent)
                    + abs(pixel.blueComponent - base.blueComponent) > 0.015
            }.count
        }

        #expect(await eventually { doodlePixelCount() == 0 }, "\(theme): wallpaper off should draw pure uniform canvas")

        harness.appearance.chatWallpaper = true
        #expect(
            await eventually { (doodlePixelCount() ?? 0) > 20 },
            "\(theme): wallpaper on should draw repeating doodle strokes over canvas")

        harness.appearance.chatWallpaper = false
        #expect(await eventually { doodlePixelCount() == 0 }, "\(theme): toggling wallpaper off should clear doodles")
    }

    // capability: app.themes
    @Test("Switching to a workspace with a theme override updates the sidebar without shifting layout")
    func perWorkspaceThemeSwitch() async throws {
        let saved = [
            "appearance.mode", "appearance.theme", "appearance.chatWallpaper", "appearance.increaseContrast",
            "appearance.workspaceThemes",
        ].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        let harness = Harness()
        defer { harness.close() }
        let secondSpaceID = "!second.space:example.org"
        harness.matrix.workspaces.append(Workspace(id: secondSpaceID, name: "Design"))
        harness.matrix.rooms.append(
            ChatRoom(id: "!design.room:example.org", name: "design", spaceIDs: [secondSpaceID]))
        harness.appearance.mode = .light
        harness.appearance.systemIsDark = false
        harness.appearance.theme = .neutral
        harness.appearance.setTheme(.aubergine, for: secondSpaceID)
        harness.window.appearance = NSAppearance(named: .aqua)
        #expect(await harness.settle())

        let beforeLeft = try #require(harness.conversationLeft)
        let beforeSearch = try #require(harness.searchField).convert(try #require(harness.searchField).bounds, to: nil)
        #expect(harness.appearance.colors.theme == .neutral)

        let entries = WorkspaceRail.entries(workspaces: harness.matrix.workspaces, rooms: harness.matrix.rooms)
        let targetIndex = try #require(entries.firstIndex { $0?.id == secondSpaceID })
        harness.menu("workspace-\(targetIndex + 1)")

        #expect(await eventually { harness.appearance.colors.theme == .aubergine })
        await drainMainActor()
        harness.hosting.layoutSubtreeIfNeeded()
        let afterSearch = try #require(harness.searchField).convert(try #require(harness.searchField).bounds, to: nil)
        let afterLeft = try #require(harness.conversationLeft)
        #expect(abs(afterLeft - beforeLeft) < 0.5)
        #expect(abs(afterSearch.minY - beforeSearch.minY) < 0.5)
        #expect(abs(afterSearch.height - beforeSearch.height) < 0.5)

        let canvas = try #require(NSColor(harness.appearance.colors.canvas).usingColorSpace(.sRGB))
        let sidebarPoint = CGPoint(x: 40, y: 180)
        #expect(
            await eventually {
                guard let bitmap = harness.compositedBitmap(),
                    let pixel = harness.compositedColor(in: bitmap, at: sidebarPoint)
                else { return false }
                return abs(pixel.redComponent - canvas.redComponent)
                    + abs(pixel.greenComponent - canvas.greenComponent)
                    + abs(pixel.blueComponent - canvas.blueComponent) > 0.3
            })
    }

    // capability: app.themes
    @Test("Preferences groups six themes, scopes workspace overrides, and keeps wallpaper and contrast toggles enabled")
    func preferencesThemeControlsAndScope() async throws {
        let saved = [
            "appearance.mode", "appearance.theme", "appearance.chatWallpaper", "appearance.increaseContrast",
            "appearance.workspaceThemes",
        ].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        let harness = Harness()
        defer { harness.close() }
        harness.appearance.theme = .glass
        harness.appearance.chatWallpaper = true
        harness.appearance.increaseContrast = false
        #expect(await harness.settle())

        VoiceOver.listen()
        defer { VoiceOver.done() }

        let activeWorkspace = try #require(harness.matrix.workspaces.first)
        harness.menu("preferences")
        #expect(await eventually { !harness.accessible("All workspaces").isEmpty })
        #expect(!harness.accessible(activeWorkspace.name).isEmpty)

        // All six curated themes appear; removed legacy themes and dead Window gradient toggle are gone.
        for theme in ColorTheme.allCases {
            #expect(!harness.accessible(theme.name).isEmpty, "Missing theme tile \(theme.name)")
        }
        #expect(harness.accessible("Window gradient").isEmpty)
        #expect(harness.accessible("Slate").isEmpty)
        #expect(harness.accessible("Lagoon").isEmpty)
        #expect(harness.accessible("Midnight").isEmpty)

        // Both Chat wallpaper and Increase contrast switches stay enabled across neutral and colored themes.
        for theme in [ColorTheme.neutral, .glass, .aubergine] {
            harness.appearance.theme = theme
            await drainMainActor()
            let switches = harness.shown().compactMap { $0 as? NSSwitch }
            #expect(switches.count >= 3)
            #expect(switches.allSatisfy { $0.isEnabled }, "\(theme): no appearance switch should be disabled")
        }

        // Switching scope to the active workspace sets a per-workspace override without changing global theme.
        harness.appearance.theme = .glass
        let workspaceTab = try #require(harness.accessible(activeWorkspace.name).first)
        #expect(workspaceTab.accessibilityPerformPress?() == true)
        await drainMainActor()
        let jadeTile = try #require(harness.accessible("Jade").first)
        #expect(jadeTile.accessibilityPerformPress?() == true)
        #expect(await eventually { harness.appearance.workspaceThemes[activeWorkspace.id] == .jade })
        #expect(harness.appearance.theme == .glass)

        // "Use default" clears the workspace override back to the global theme.
        #expect(await eventually { !harness.accessible("Use default").isEmpty })
        let reset = try #require(harness.accessible("Use default").first)
        #expect(reset.accessibilityPerformPress?() == true)
        #expect(await eventually { harness.appearance.workspaceThemes[activeWorkspace.id] == nil })
        #expect(harness.appearance.effectiveTheme(for: activeWorkspace.id) == .glass)
    }

    @Test("Each divider takes the pointer a few points to either side of its line")
    func dividerHitArea() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        try harness.openThread()
        #expect(await eventually { harness.dividers == 2 })
        let content = try #require(harness.window.contentView)
        for divider in harness.shown().filter({ String(describing: type(of: $0)) == "ResizePointerView" }) {
            let line = divider.convert(divider.bounds, to: nil).midX
            for x in [line - 5, line + 5] {
                let hit = content.hitTest(content.convert(NSPoint(x: x, y: 450), from: nil))
                #expect(hit === divider, "\(x) of \(line): \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
            }
        }
    }

    @Test("Opening a thread in the open channel leaves the conversation as it is")
    func threadKeepsConversation() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        let newest = try harness.newest()
        let before = newest.convert(newest.bounds, to: nil)
        try harness.openThread()
        #expect(await eventually { harness.dividers == 2 })
        // The same row, not the conversation loaded again: it keeps its place against the composer.
        #expect(newest.window != nil)
        #expect(abs(newest.convert(newest.bounds, to: nil).minY - before.minY) < 1)
    }

    @Test("The composer spans the conversation pane between its edge insets and grows with the pane")
    func composerInColumn() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        func measured() throws -> (pane: CGRect, field: CGRect) {
            let timeline = try #require(harness.shown().first { $0 is TimelineScrollView })
            let editor = try #require(harness.shown().first { ($0 as? NSTextView)?.isEditable == true })
            return (timeline.convert(timeline.bounds, to: nil), editor.convert(editor.bounds, to: nil))
        }
        let (pane, field) = try measured()
        // The composer spans the pane between its 20 pt edge insets; its text field sits inside, between its buttons.
        #expect(field.minX > pane.minX + 20 && field.maxX < pane.maxX - 20, "\(field) in \(pane)")
        // Widening the pane widens the composer by the same amount, keeping its leading edge fixed to the pane's inset.
        harness.window.setContentSize(NSSize(width: harness.window.frame.width + 300, height: 800))
        #expect(await harness.settle())
        let (widerPane, widerField) = try measured()
        #expect(widerPane.width > pane.width)
        #expect(abs((widerField.minX - widerPane.minX) - (field.minX - pane.minX)) < 1)
        #expect(abs((widerField.width - field.width) - (widerPane.width - pane.width)) < 1)
    }

    @Test("The composer sits 12 pt above the window's edge, with air between it and the newest message")
    func composerMargins() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        let editor = try #require(harness.shown().first { ($0 as? NSTextView)?.isEditable == true })
        let field = editor.convert(editor.bounds, to: nil)
        // A window's own coordinates start at its bottom. The composer is 40 tall, around its one line of text.
        #expect(abs(field.midY - (12 + 20)) <= 1, "\(field)")
        let messages = harness.shown().compactMap { $0 as? TimelineCell }.filter {
            if case .message = $0.entry?.kind { return true }
            return false
        }
        let newest = try #require(messages.map { $0.convert($0.bounds, to: nil).minY }.min())
        #expect(abs(newest - (field.midY + 20) - 26) <= 1, "\(newest) over \(field)")
    }

    @Test("A thread left open in a channel is open again on coming back to the channel")
    func threadSurvivesLeaving() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        try harness.openThread()
        #expect(await eventually { harness.dividers == 2 })
        // The thread's first message, in the pane right of the conversation's divider.
        let root = try #require(harness.messages.last?.body)
        func threadShown() -> Bool {
            let shown = harness.shown()
            guard
                let edge = shown.filter({ String(describing: type(of: $0)) == "ResizePointerView" })
                    .map({ $0.convert($0.bounds, to: nil).maxX }).max()
            else { return false }
            return shown.contains {
                ($0 as? MessageTextView)?.string == root && $0.convert($0.bounds, to: nil).minX > edge
            }
        }
        #expect(await eventually { threadShown() })

        let channel = harness.matrix.selectedRoomID
        harness.menu("next-conversation")
        #expect(await eventually { harness.dividers == 1 })
        harness.menu("previous-conversation")
        #expect(await eventually { harness.matrix.selectedRoomID == channel })
        #expect(await eventually { harness.dividers == 2 && threadShown() })
    }

    @Test("At 150% zoom an open thread stays inside the panel")
    func paneFitsAtZoom() async throws {
        let harness = Harness(zoom: 1.5)
        defer { harness.close() }
        #expect(await harness.settle())
        try harness.openThread()
        // The rightmost drop target is the thread's, as wide as the pane, which ends at the window's edge.
        let panelEdge = harness.window.frame.width
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
        harness.resize(980)
        #expect(
            await eventually { harness.dividers == 1 && !harness.sidebarShown && harness.conversationLeft == 0 })
        harness.resize(700)
        #expect(await eventually { harness.dividers == 0 && harness.searchFieldShown })
        harness.resize(560)
        #expect(await eventually { !harness.searchFieldShown })

        // Closing the thread brings the sidebar back on its own.
        harness.resize(980)
        #expect(await eventually { harness.dividers == 1 && !harness.sidebarShown })
        harness.menu("toggle-pane")
        #expect(await eventually { harness.dividers == 1 && harness.sidebarShown })

        harness.resize(1_440)
        try harness.openThread()
        #expect(await eventually { harness.dividers == 2 && harness.sidebarShown && harness.searchFieldShown })
    }

    @Test("Too narrow for a thread beside the conversation, the thread takes its place instead of cutting it")
    func threadTakesConversationsPlace() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        try harness.openThread()
        harness.resize(700)
        // The conversation's drop target and the thread's, one over the other, as wide as each other.
        #expect(
            await eventually {
                let targets = harness.shown().compactMap { $0 as? UploadDropView }
                    .map { $0.convert($0.bounds, to: nil) }
                return targets.count == 2 && targets[0].minX == targets[1].minX && targets[0].maxX == targets[1].maxX
            })
    }

    @Test(
        "What covers the conversation keeps keys, drops and commands from it, and its composer has the keyboard back after"
    )
    func coveredComposer() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        let window = harness.window
        let composer = try #require(
            harness.shown().first { ($0 as? NSTextView)?.isEditable == true } as? NSTextView)
        let drop = try #require(harness.shown().first { $0 is UploadDropView } as? UploadDropView)
        let files = FakeDrag(files: [URL(fileURLWithPath: #filePath)], over: window)
        #expect(await eventually { drop.draggingEntered(files) == .copy })
        #expect(window.makeFirstResponder(composer))
        // Whatever has the keyboard gets the text; nothing hands it the keyboard first.
        func types(_ text: String) -> Bool {
            window.firstResponder?.insertText(text)
            return composer.string.hasSuffix(text)
        }
        func backAndTypes(_ text: String) async -> Bool {
            await eventually { window.firstResponder === composer } && types(text)
        }

        // The media viewer over the window.
        var photo = ChatMessage(
            id: "$photo", roomID: try #require(harness.matrix.selectedRoomID), senderID: "@ana:example.org",
            senderName: "ana", body: "photo.png", timestamp: Date(timeIntervalSince1970: 1_762_700_000))
        photo.kind = "m.image"
        photo.attachment = MessageAttachment(
            name: "photo.png", url: "mxc://example.org/photo", mimeType: "image/png", width: 400, height: 300)
        harness.matrix.messages.append(photo)
        let m = Metrics()
        // Hit-testing takes a point in the frame around the content, which is the window's own.
        let frame = try #require(window.contentView?.superview)
        // In the photo's row, in the text's column, halfway down, on the photo.
        func photoPoint() -> NSPoint? {
            guard let cell = harness.shown().first(where: { ($0 as? TimelineCell)?.entry?.id == photo.id }) else {
                return nil
            }
            let row = cell.convert(cell.bounds, to: nil)
            let point = NSPoint(
                x: row.minX + m.conversationInset(thread: false) + m.conversationText(thread: false) + 40,
                y: row.midY)
            var view = frame.hitTest(point)
            while let shown = view, !(shown is TimelineCell) { view = shown.superview }
            return view === cell ? point : nil
        }
        #expect(await eventually { photoPoint() != nil })
        try await harness.click(CGRect(origin: try #require(photoPoint()), size: .zero))
        func stage() -> NSView? { harness.shown().first { $0 is MediaStageView } }
        #expect(await eventually { stage() != nil })
        #expect(await eventually { drop.draggingEntered(files) == [] })
        #expect(!types("a"))
        stage()?.keyDown(
            with: try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)))
        #expect(await eventually { stage() == nil })
        #expect(await backAndTypes("b"))

        // A dialog, and one closed as soon as it opened.
        harness.menu("preferences")
        #expect(await eventually { harness.shown().contains { $0 is NSSwitch } })
        #expect(await eventually { window.firstResponder !== composer })
        #expect(!types("c"))
        harness.menu("mark-read")
        #expect(await backAndTypes("d"))
        harness.menu("preferences")
        harness.menu("mark-read")
        #expect(await backAndTypes("e"))

        // The sidebar drawer, in a narrow window, which Esc closes.
        harness.resize(700)
        #expect(await eventually { !harness.sidebarShown })
        harness.menu("toggle-sidebar")
        #expect(await eventually { window.firstResponder !== composer })
        #expect(!types("f"))
        #expect(drop.draggingEntered(files) == [])
        harness.menu("mark-read")
        #expect(await backAndTypes("g"))

        // A thread in its place, which Esc closes without marking the conversation read.
        try harness.openThread()
        #expect(await eventually { harness.shown().compactMap { $0 as? UploadDropView }.count == 2 })
        #expect(await eventually { window.firstResponder !== composer })
        #expect(!types("h"))
        #expect(drop.draggingEntered(files) == [])
        // ⌘U with neither composer focused attaches to neither.
        window.makeFirstResponder(nil)
        harness.menu("attach")
        await drainMainActor()
        // Required: the file panel a failure leaves open can't be dismissed from here.
        try #require(window.attachedSheet == nil)
        harness.menu("mark-read")
        #expect(await eventually { harness.shown().compactMap { $0 as? UploadDropView }.count == 1 })
        #expect(await backAndTypes("i"))
    }

    @Test("What a profile or the drawer lies over can't be activated, and a cover adds nothing to VoiceOver's path")
    func coveredRoute() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        VoiceOver.listen()
        defer { VoiceOver.done() }
        // Nothing between the window and the control, as a cover that covers nothing would add.
        func direct(_ text: String) -> Bool {
            accessibilityPath(to: text, in: harness.hosting).map { !$0.dropFirst().dropLast().contains("AXGroup") }
                == true
        }
        func enabled(_ text: String) -> Bool {
            harness.accessible(text).contains { $0.isAccessibilityEnabled?() == true }
        }
        #expect(direct("Message"))
        harness.resize(700)
        harness.menu("people")
        // Everyone with an "a" in their name, Alex and Julia among them.
        func search() -> NSTextField? {
            harness.shown().first { ($0 as? NSTextField)?.placeholderString == "Search people" } as? NSTextField
        }
        #expect(await eventually { search() != nil })
        #expect(direct("Search people"))
        #expect(harness.window.makeFirstResponder(search()))
        harness.window.firstResponder?.insertText("a")
        #expect(await eventually { enabled("Julia") })
        #expect(harness.accessible("Alex").contains { $0.accessibilityPerformPress?() == true })
        #expect(await eventually { !harness.accessible("Close profile").isEmpty })
        #expect(!enabled("Julia") && !enabled("Search people"))
        #expect(!harness.accessible("Julia").contains { $0.accessibilityPerformPress?() == true })
        #expect(harness.accessible("Close profile").contains { $0.accessibilityPerformPress?() == true })
        #expect(await eventually { enabled("Julia") })

        // The sidebar drawer over the whole column, the toolbar too.
        harness.menu("toggle-sidebar")
        #expect(await eventually { !enabled("Search people") && !enabled("Back") })
        harness.menu("toggle-sidebar")
        #expect(await eventually { enabled("Search people") })
    }

    @Test("In a narrow window an error sits under the thread's header, so Close thread still closes the thread")
    func bannerUnderPaneHeader() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        try harness.openThread()
        harness.resize(700)
        func targets() -> [CGRect] {
            harness.shown().compactMap { $0 as? UploadDropView }.map { $0.convert($0.bounds, to: nil) }
        }
        #expect(await eventually { targets().count == 2 })
        harness.matrix.errorMessage = "The server didn’t answer."
        // The thread's drop target is the one under the toolbar; Close thread ends its header.
        let pane = try #require(targets().min { $0.maxY < $1.maxY })
        let m = Metrics()
        let close = CGRect(
            x: pane.maxX - m.conversationInset(thread: true) - m.iconButton / 2, y: pane.maxY - m.paneHeader / 2,
            width: 0, height: 0)
        try await harness.click(close)
        #expect(await eventually { targets().count == 1 })
        #expect(harness.matrix.errorMessage != nil)
    }

    @Test(
        "The composer's text aligns with message text in comfortable density, and compact messages sit inline after time and sender",
        arguments: [MessageDensity.comfortable, .compact])
    func composerTextOnMessageText(density: MessageDensity) async throws {
        let harness = Harness()
        defer { harness.close() }
        harness.appearance.density = density
        #expect(await harness.settle())
        func textStart(_ view: NSTextView) -> CGFloat {
            let x = view.textContainerOrigin.x + (view.textContainer?.lineFragmentPadding ?? 0)
            return view.convert(NSPoint(x: x, y: 0), to: nil).x
        }
        let message = try #require(try harness.newest() as? NSTextView)
        let composer = try #require(harness.shown().first { ($0 as? NSTextView)?.isEditable == true } as? NSTextView)
        if density == .comfortable {
            #expect(
                abs(textStart(composer) - textStart(message)) <= 1, "\(textStart(composer)) and \(textStart(message))")
        } else {
            #expect(
                textStart(message) > textStart(composer),
                "Compact message body should sit inline after time and sender: \(textStart(composer)) vs \(textStart(message))"
            )
        }
    }

    @Test("Also send to names a private channel with its lock, as a public one shows its #")
    func alsoSendToMarksPrivate() async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        try harness.openThread()
        #expect(await eventually { harness.dividers == 2 })
        let canvas = try #require(NSColor(harness.appearance.colors.canvas).usingColorSpace(.sRGB))
        // Where the checkbox's words end: the last column of ink on its line, right of the box.
        func wordsEnd() throws -> CGFloat {
            let box = try #require(harness.shown().first { $0 is NSButton })
            let frame = box.convert(box.bounds, to: nil)
            harness.hosting.layoutSubtreeIfNeeded()
            let image = try #require(harness.hosting.bitmapImageRepForCachingDisplay(in: harness.hosting.bounds))
            harness.hosting.cacheDisplay(in: harness.hosting.bounds, to: image)
            let scale = CGFloat(image.pixelsWide) / harness.hosting.bounds.width
            let y = Int((harness.hosting.bounds.height - frame.midY) * scale)
            let ink = (Int(frame.maxX * scale)..<image.pixelsWide).last { x in
                (y - 8...y + 8).contains { row in
                    guard let pixel = image.colorAt(x: x, y: row) else { return false }
                    return abs(pixel.redComponent - canvas.redComponent)
                        + abs(pixel.greenComponent - canvas.greenComponent)
                        + abs(pixel.blueComponent - canvas.blueComponent) > 0.3
                }
            }
            return try CGFloat(#require(ink)) / scale
        }
        let open = try wordsEnd()
        let index = try #require(harness.matrix.rooms.firstIndex { $0.id == harness.matrix.selectedRoomID })
        harness.matrix.rooms[index].isPrivate = true
        // The same words but for the mark before the name: the lock is wider than a #, in any weight.
        #expect(await eventually { (try? wordsEnd()).map { $0 - open >= 2 } == true })
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

    @Test("Hiding the sidebar by hand at full width gives the conversation the whole window, and it comes back")
    func hiddenByHand() async {
        let key = "layout.sidebarHidden"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(false, forKey: key)
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        harness.menu("toggle-sidebar")
        #expect(await eventually { !harness.sidebarShown && harness.conversationLeft == 0 })
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

    @Test("A modal dims the whole window, toolbar included, which then takes no clicks", arguments: [1, 1.5])
    func modalCoversToolbar(zoom: Double) async throws {
        let harness = Harness(zoom: zoom)
        defer { harness.close() }
        #expect(await harness.settle())
        let search = try #require(harness.searchField)
        let field = search.convert(search.bounds, to: nil)
        harness.menu("preferences")
        // Preferences opens on Appearance, with its profile photos switch.
        #expect(await eventually { harness.shown().contains { $0 is NSSwitch } })

        // The scrim is in once the canvas no longer shows along the window's bottom edge, under the panel.
        let canvas = try #require(NSColor(harness.appearance.colors.canvas).usingColorSpace(.sRGB))
        let edge = CGRect(x: 0, y: 0, width: harness.hosting.bounds.width, height: 2)
        #expect(
            await eventually {
                harness.longestRun(in: edge) {
                    abs($0.redComponent - canvas.redComponent) + abs($0.greenComponent - canvas.greenComponent)
                        + abs($0.blueComponent - canvas.blueComponent) < 0.03
                } == 0
            })
        // It covers the toolbar too: a click on the search field doesn't reach it.
        let hit = harness.hosting.hitTest(NSPoint(x: field.midX, y: field.midY))
        #expect(hit.map { $0 !== search && !$0.isDescendant(of: search) } ?? true)
    }

    // capability: auth.sign-out
    @Test("Leaving the sample workspace from Preferences asks nothing and goes straight to sign-in")
    func leavePreview() async {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settle())
        VoiceOver.listen()
        defer { VoiceOver.done() }
        func press(_ text: String) -> Bool {
            harness.accessible(text).contains { $0.accessibilityPerformPress?() == true }
        }
        harness.menu("preferences")
        #expect(await eventually { press("Account") })
        #expect(await eventually { press("Leave preview") })
        // The sign-in screen's own way back into the sample.
        #expect(await eventually { !harness.accessible("Try it without signing in").isEmpty })
        #expect(harness.accessible("Sign out of Slatrix?").isEmpty)
    }
}
