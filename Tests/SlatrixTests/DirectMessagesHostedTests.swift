import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// The DMs view in the whole window, offscreen, over the sample workspace; needs an awake display.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct DirectMessagesHostedTests {
    // capability: home.dms
    @Test("DMs lists the conversations in the sidebar column, newest first, and opens the one picked beside it")
    func listInColumn() async throws {
        _ = NSApplication.shared
        UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicsEnabled": false])
        let matrix = MatrixService()
        matrix.enterPreview()
        let now = Date()
        // Newest first is Sam, Julia, Alex: not their order by name.
        for (name, age) in [("Sam", 60.0), ("Julia", 3_600), ("Alex", 7_200)] {
            let index = try #require(matrix.rooms.firstIndex { $0.isDirect && $0.name == name })
            matrix.rooms[index].latest = LatestMessage(body: "Note from \(name)", timestamp: now - age, isOwn: false)
        }
        func id(_ name: String) -> String? { matrix.rooms.first { $0.name == name }?.id }
        let metrics = Metrics(zoom: 1)
        let appearance = AppearanceStore()
        let hosting = NSHostingView(
            rootView: RootView(matrix: matrix).environmentObject(appearance).environment(\.metrics, metrics))
        let window = offscreenWindow(NSSize(width: 1_440, height: 900))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        /// A sidebar column's search field, by its prompt, in window coordinates.
        func field(_ prompt: String) -> NSRect? {
            hosting.layoutSubtreeIfNeeded()
            return views(hosting).compactMap { $0 as? NSTextField }.first { $0.placeholderString == prompt }
                .map { $0.convert($0.bounds, to: nil) }
        }
        func menu(_ action: String) {
            NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": action])
        }

        #expect(await eventually { field("Find a conversation…") != nil })
        // A channel read first, for going back to later.
        let first = matrix.selectedRoomID
        menu("next-conversation")
        #expect(await eventually { matrix.selectedRoomID != first })
        let channel = matrix.selectedRoomID
        menu("dms")
        let column = metrics.rail + SidebarLayout.defaultWidth
        #expect(await eventually { field("Find a DM").map { $0.maxX <= column } == true })
        // Beside the list, the newest direct message opens.
        #expect(await eventually { matrix.selectedRoomID == id("Sam") })

        // The second row, Julia's, a row and a half under the Unreads switch.
        let below = try #require(
            views(hosting).compactMap { $0 as? NSSwitch }.first.map { $0.convert($0.bounds, to: nil) })
        let row = NSHostingView(
            rootView: DirectMessageRow(room: ChatRoom(id: "!r:example.org", name: "Row", isDirect: true))
                .frame(width: SidebarLayout.defaultWidth).environmentObject(appearance).environment(\.metrics, metrics)
        ).fittingSize.height
        let point = NSPoint(x: metrics.rail + SidebarLayout.defaultWidth / 2, y: below.minY - metrics.sp8 - row * 1.5)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            await drainMainActor()
            window.sendEvent(
                try #require(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        #expect(await eventually { matrix.selectedRoomID == id("Julia") })
        #expect(field("Find a DM") != nil)

        // The next conversation is the next row down.
        menu("next-conversation")
        #expect(await eventually { matrix.selectedRoomID == id("Alex") })
        #expect(field("Find a DM") != nil)

        // Switching workspace brings its conversations back.
        menu("workspace-1")
        #expect(await eventually { field("Find a conversation…") != nil && field("Find a DM") == nil })

        // Back in DMs, the direct message read last stays open; going back to a channel leaves the list.
        menu("dms")
        #expect(await eventually { field("Find a DM") != nil })
        #expect(matrix.selectedRoomID == id("Alex"))
        for name in ["Julia", "Sam"] {
            menu("back")
            #expect(await eventually { matrix.selectedRoomID == id(name) && field("Find a DM") != nil })
        }
        menu("back")
        #expect(
            await eventually {
                matrix.selectedRoomID == channel && field("Find a conversation…") != nil && field("Find a DM") == nil
            })
    }

    @Test("In a narrow window, DMs picked in the drawer from another page keeps the drawer open on the list")
    func drawer() async throws {
        _ = NSApplication.shared
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
        func shows(_ prompt: String) -> Bool {
            hosting.layoutSubtreeIfNeeded()
            return views(hosting).contains { ($0 as? NSTextField)?.placeholderString == prompt }
        }
        func menu(_ action: String) {
            NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": action])
        }
        #expect(await eventually { matrix.selectedRoomID != nil && shows("Find a conversation…") })
        window.setContentSize(NSSize(width: 480, height: 900))
        #expect(await eventually { !shows("Find a conversation…") })
        menu("activity")
        await drainMainActor()
        menu("toggle-sidebar")
        #expect(await eventually { shows("Find a conversation…") })
        menu("dms")
        let direct = Set(matrix.rooms.filter(\.isDirect).map(\.id))
        #expect(await eventually { matrix.selectedRoomID.map(direct.contains) == true })
        // The page change that closed it lands within a frame or two of the DM opening.
        let closed = await eventually(timeout: .seconds(1)) { !shows("Find a DM") }
        #expect(!closed)
    }
}
