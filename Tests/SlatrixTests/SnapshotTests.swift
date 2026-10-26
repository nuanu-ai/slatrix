import AppKit
import SwiftUI
import Testing

@testable import Slatrix

extension Tag {
    @Tag static var snapshots: Tag
}

/// Renders the sample workspace in-process and writes PNGs to `.build/snapshots/` for a person to look at.
/// Opt in with `SLATRIX_SNAPSHOTS=1 swift test --filter Snapshots`; nothing is compared automatically.
@MainActor
@Suite(.serialized, .tags(.snapshots), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_SNAPSHOTS"] != nil))
struct Snapshots {
    enum Theme: String, CaseIterable { case light, dark }

    @Test("Channel and thread windows", arguments: [1, 1.5, 2], Theme.allCases)
    func window(zoom: Double, theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark

        let hosting = NSHostingView(
            rootView: RootView(matrix: matrix).environmentObject(appearance).environment(\.metrics, Metrics(zoom: zoom))
        )
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1440, height: 900), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        // Still off screen, but ordered in, so the window server composites it for `settledImage`.
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }

        let name = "\(Int(zoom * 100))-\(theme.rawValue)"
        _ = try await settledImage(hosting)
        for editor in textViews(in: hosting) where editor.isEditable {
            editor.insertText("Drafting a reply with **bold** text", replacementRange: editor.selectedRange())
        }
        try write(await settledImage(hosting), "channel-\(name)")

        // Open a thread through the message's own context menu, the same item a right-click shows.
        // The sample workspace answers any thread with the same replies, so use a message that is always on screen.
        let thread = try #require(textViews(in: hosting).last { !$0.isEditable && !$0.string.isEmpty })
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let item = try #require(thread.menu(for: event)?.items.first { $0.identifier?.rawValue == "thread" })
        _ = item.target?.perform(item.action, with: item)
        _ = try await settledImage(hosting)
        for editor in textViews(in: hosting) where editor.isEditable && editor.string.isEmpty {
            editor.insertText("Replying in the thread", replacementRange: editor.selectedRange())
        }
        try write(await settledImage(hosting), "thread-\(name)")

        // The profile card, from the same message's "View profile" item.
        let profile = try #require(thread.menu(for: event)?.items.first { $0.identifier?.rawValue == "profile" })
        _ = profile.target?.perform(profile.action, with: profile)
        try write(await settledImage(hosting), "profile-\(name)")
    }

    @Test("Sidebar", arguments: SidebarPalette.allCases, Theme.allCases)
    func sidebar(palette: SidebarPalette, theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        let savedPalette = UserDefaults.standard.object(forKey: "appearance.palette")
        defer {
            UserDefaults.standard.set(savedMode, forKey: "appearance.mode")
            UserDefaults.standard.set(savedPalette, forKey: "appearance.palette")
        }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        appearance.palette = palette
        let sidebar = SidebarView(
            matrix: matrix, route: .constant(.home), workspaceID: .constant("preview.workspace"),
            search: .constant(""), draftRoomIDs: ["preview.room.3"], onSelect: { _ in }, onCreate: { _ in },
            onPreferences: {}, onProfile: {}, onSignOut: {}, onMarkUnread: { _ in }, onMarkRead: { _ in },
            onInviteWorkspace: { _ in }, onEditWorkspace: { _ in }, onNotifications: { _ in }, onBrowseChannels: {})
        let hosting = NSHostingView(
            rootView: sidebar.frame(width: 68 + 280, height: 760).environmentObject(appearance))
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 68 + 280, height: 760), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        try write(await settledImage(hosting), "sidebar-\(palette.rawValue)-\(theme.rawValue)")
    }

    @Test("Component gallery", arguments: Theme.allCases)
    func gallery(theme: Theme) async throws {
        _ = NSApplication.shared
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(rootView: ComponentGallery().environmentObject(appearance))
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: hosting.fittingSize),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        try write(await settledImage(hosting), "gallery-\(theme.rawValue)")
    }

    @Test("Mentions in messages and the composer", arguments: Theme.allCases)
    func mentions(theme: Theme) async throws {
        _ = NSApplication.shared
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        func message(_ sender: String, _ body: String, html: String? = nil) -> ChatMessage {
            ChatMessage(
                id: sender + body, roomID: "!room:example.org", senderID: "@\(sender.lowercased()):example.org",
                senderName: sender, body: body, formattedBody: html,
                timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        }
        let alice = "<a href=\"https://matrix.to/#/@alice:example.org\">Alice Liddell</a>"
        let me = "<a href=\"https://matrix.to/#/@me:example.org\">Dmitry</a>"
        let view = VStack(alignment: .leading, spacing: 0) {
            MessageRow(message: message("Bob", "-", html: "Hey \(alice), can you review the deck before standup?"))
            MessageRow(message: message("Carol", "-", html: "\(me) the build is green, @room please pull"))
            MessageRow(message: message("Dave", "Pinging @carol:example.org and @erin:example.org about it"))
            MessageComposer(
                text: .constant("Thanks [Alice Liddell](https://matrix.to/#/@alice:example.org) "),
                placeholder: "Message #design", members: [], onSend: { _, _ in }, onTyping: { _ in }
            ).padding(16)
        }
        .frame(width: 560).background(appearance.colors.canvas)
        .environment(
            \.mentions,
            MentionContext(me: "@me:example.org", members: [ChatUser(id: "@carol:example.org", name: "Carol Chen")])
        )
        .environmentObject(appearance)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: hosting.fittingSize),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        try write(await settledImage(hosting), "mentions-\(theme.rawValue)")
    }

    /// Captures until the frame stops changing for 300 ms, so async text, symbols and layout have arrived.
    ///
    /// The window server's composite, not `cacheDisplay`: that draws through `CALayer.render(in:)`, which skips layer
    /// filters, and SwiftUI tints some symbols (the composer's emoji, list and code icons) with a `multiplyColor`
    /// filter over a white glyph, so they vanished on light backgrounds.
    private func settledImage(_ view: NSView) async throws -> Data {
        let window = try #require(view.window)
        var previous = Data()
        var unchanged = 0
        for _ in 0..<400 {
            view.layoutSubtreeIfNeeded()
            // Nil until the window server has the window's first frame. Options: including window (8); ignore
            // framing (1) and best resolution (8).
            let image = Self.windowImage(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue()
            let png =
                image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) } ?? Data()
            unchanged = png == previous ? unchanged + 1 : 0
            if unchanged == 6 && !png.isEmpty { return png }
            previous = png
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Rendering never settled")
        return previous
    }

    /// `CGWindowListCreateImage`, unavailable in the SDK but still in the OS; reading the process's own window needs
    /// no screen recording permission, which ScreenCaptureKit would.
    private static let windowImage = unsafeBitCast(
        dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"),
        to: (@convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?).self)

    private func write(_ png: Data, _ name: String) throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
}
