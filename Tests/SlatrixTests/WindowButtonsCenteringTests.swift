import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// The window buttons against a bare title bar along the top of a titled window, without the rest of the window.
@MainActor
struct WindowButtonsCenteringTests {
    @Test(
        "The window buttons sit inset from the corner and hold the title bar's midline through a resize from any edge",
        // The bar at 100% and 150% zoom.
        arguments: [40.0, 60.0])
    func holdThroughResize(barHeight: Double) async throws {
        let window = offscreenWindow(
            NSSize(width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        defer { window.close() }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Hosted, as the app's window is: SwiftUI sizes its views in the window's layout pass, after the frame.
        let hosting = NSHostingView(
            rootView: Color.clear.frame(height: barHeight).background(WindowButtonsCentering())
                .frame(maxHeight: .infinity, alignment: .top))
        window.contentView = hosting
        let close = try #require(window.standardWindowButton(.closeButton))
        func offset() -> CGFloat { close.convert(close.bounds, to: nil).midY - (hosting.bounds.height - barHeight / 2) }
        #expect(await eventually { abs(offset()) <= 1 }, "\(offset())")
        // Inset from the corner as far from the left edge as from the top, not against the window's edge.
        let frame = close.convert(close.bounds, to: nil)
        #expect(abs(frame.minX - (hosting.bounds.height - frame.maxY)) <= 1, "\(frame)")

        // A live resize sets the window's frame and draws it in one go, so each frame is checked right after, with
        // no turn of the run loop between. Dragging the left edge changes the width, the top edge the height, and
        // the top left corner both. Only the size reaches the views, so the other edges and corners take these paths.
        for (edge, widthChange, heightChange) in [("left", -20.0, 0.0), ("top", 0, -20), ("corner", -20, -20)] {
            for step in 1...3 {
                let frame = window.frame
                window.setFrame(
                    NSRect(
                        x: frame.minX - widthChange, y: frame.minY, width: frame.width + widthChange,
                        height: frame.height + heightChange), display: true)
                #expect(abs(offset()) <= 1, "\(edge), step \(step): \(offset())")
            }
        }
    }

    @Test(
        "The Hide sidebar button shares the window buttons' vertical midline in default and framed themes",
        arguments: [ColorTheme.standard, .aubergine])
    func hideSidebarAlignsWithWindowButtons(theme: ColorTheme) async throws {
        _ = NSApplication.shared
        VoiceOver.listen()
        defer { VoiceOver.done() }
        let savedTheme = UserDefaults.standard.object(forKey: "appearance.theme")
        defer { UserDefaults.standard.set(savedTheme, forKey: "appearance.theme") }
        let appearance = AppearanceStore()
        appearance.theme = theme
        let m = Metrics(zoom: 1)
        let matrix = MatrixService.scratch()
        matrix.workspaces = [
            Workspace(id: "!space:example.org", name: "Very Long Workspace Name That Must Truncate Cleanly")
        ]
        let window = offscreenWindow(
            NSSize(width: 240, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        defer {
            window.contentView = nil
            window.close()
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let hosting = NSHostingView(
            rootView: SidebarView(
                matrix: matrix, route: .constant(.home), workspaceID: .constant("!space:example.org"),
                directMessageSearch: .constant(""), unreadDirectMessagesOnly: .constant(false), draftRoomIDs: [],
                onSelect: { _ in }, onCreate: { _ in }, onPreferences: {}, onProfile: {}, onSignOut: {},
                onMarkUnread: { _ in }, onMarkRead: { _ in }, onInviteWorkspace: { _ in }, onEditWorkspace: { _ in },
                onNotifications: { _ in }, onHide: {}, onBrowseChannels: {}, collapsed: .constant([])
            )
            .padding([.leading, .vertical], m.sidebarInset)
            .frame(width: 240, height: 600)
            .background(alignment: .top) {
                Color.clear.frame(height: m.paneHeader + (theme.framed ? 2 * m.sidebarInset : 0))
                    .background(WindowButtonsCentering())
            }
            .environmentObject(appearance).environment(\.metrics, m)
            .ignoresSafeArea(.container, edges: .top))
        window.contentView = hosting
        let close = try #require(window.standardWindowButton(.closeButton))
        #expect(await eventually { !accessible("Hide sidebar", in: hosting).isEmpty })
        let hideButton = try #require(accessible("Hide sidebar", in: hosting).first)
        let closeScreen = window.convertToScreen(close.convert(close.bounds, to: nil))
        let hideScreen = hideButton.accessibilityFrame?() ?? .zero
        #expect(
            abs(hideScreen.midY - closeScreen.midY) <= 1.5,
            "\(theme): Hide sidebar midY=\(hideScreen.midY) vs close midY=\(closeScreen.midY)")

        // Long workspace names must truncate instead of pushing the compose button out of the sidebar.
        let compose = try #require(accessible("New message", in: hosting).first)
        let composeScreen = compose.accessibilityFrame?() ?? .zero
        #expect(
            composeScreen.maxX <= window.frame.maxX - m.sp4,
            "Compose button clipped past sidebar: \(composeScreen.maxX) vs \(window.frame.maxX)")
    }

    @Test("SearchBarField offers a clear button when non-empty and SearchMenu clamps inside narrow windows")
    func searchFieldClearAndMenuClamp() async throws {
        _ = NSApplication.shared
        VoiceOver.listen()
        defer { VoiceOver.done() }
        let m = Metrics(zoom: 1)
        let appearance = AppearanceStore()
        let matrix = MatrixService.scratch()
        let bar = SearchBar()
        bar.text = "deploy"
        bar.menuOpen = true
        bar.frame = CGRect(x: 40, y: 10, width: 200, height: 32)
        let window = offscreenWindow(NSSize(width: 320, height: 400))
        defer {
            window.contentView = nil
            window.close()
        }
        let hosting = NSHostingView(
            rootView: ZStack(alignment: .topLeading) {
                SearchBarField(
                    bar: bar, prompt: "Search", matrix: matrix, recents: [], visited: [], onPick: { _ in }
                ).frame(width: 200).padding(.leading, 40).padding(.top, 10)
                SearchMenu(bar: bar, matrix: matrix, recents: [], visited: [], top: 52, onPick: { _ in })
            }
            .frame(width: 320, height: 400)
            .coordinateSpace(.named(SearchBar.space))
            .environmentObject(appearance).environment(\.metrics, m))
        window.contentView = hosting
        #expect(await eventually { !accessible("Clear search", in: hosting).isEmpty })
        #expect(await eventually { !accessible("Search for “deploy”", in: hosting).isEmpty })
        let row = try #require(accessible("Search for “deploy”", in: hosting).first)
        let rowScreen = row.accessibilityFrame?() ?? .zero
        #expect(
            rowScreen.minX >= window.frame.minX, "SearchMenu overflowed left: \(rowScreen.minX) < \(window.frame.minX)")
        #expect(
            rowScreen.maxX <= window.frame.maxX, "SearchMenu overflowed right: \(rowScreen.maxX) > \(window.frame.maxX)"
        )
        let clear = try #require(accessible("Clear search", in: hosting).first)
        _ = clear.accessibilityPerformPress?()
        #expect(await eventually { bar.text.isEmpty })
    }

    @Test("Moving focus to Clear search keeps SearchBarField open and clears the query")
    func clearSearchFocusKeepsMenuOpen() async throws {
        _ = NSApplication.shared
        UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicsEnabled": false])
        VoiceOver.listen()
        defer { VoiceOver.done() }
        let m = Metrics(zoom: 1)
        let appearance = AppearanceStore()
        let matrix = MatrixService.scratch()
        let bar = SearchBar()
        bar.text = "deploy"
        let window = offscreenWindow(NSSize(width: 320, height: 200), key: true)
        defer {
            window.contentView = nil
            window.close()
        }
        let hosting = NSHostingView(
            rootView: SearchBarField(
                bar: bar, prompt: "Search", matrix: matrix, recents: [], visited: [], onPick: { _ in }
            )
            .frame(width: 240)
            .environmentObject(appearance).environment(\.metrics, m))
        window.contentView = hosting
        window.orderFrontRegardless()
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        #expect(
            await eventually {
                hosting.layoutSubtreeIfNeeded()
                return !allViews(hosting).compactMap { $0 as? NSTextField }.isEmpty
                    && !accessible("Clear search", in: hosting).isEmpty
            })
        let textField = try #require(allViews(hosting).compactMap { $0 as? NSTextField }.first)
        window.makeFirstResponder(textField)
        #expect(await eventually { bar.menuOpen })
        let clear = try #require(accessible("Clear search", in: hosting).first)
        clear.setAccessibilityFocused?(true)
        await drainMainActor()
        #expect(bar.menuOpen, "Focusing Clear search closed the search bar")
        _ = clear.accessibilityPerformPress?()
        #expect(await eventually { bar.text.isEmpty })
        #expect(bar.menuOpen, "Pressing Clear search closed the search bar")
    }
}
