import AppKit
import MatrixRustSDK
import SwiftUI
import Testing

@testable import Slatrix

extension Tag {
    @Tag static var snapshots: Tag
}

/// A conversation with nothing older, so the timeline starts at its welcome and asks for no history.
private final class StartOfTimeline: Timeline, @unchecked Sendable {
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func paginateBackwards(numEvents: UInt16) async throws -> Bool { true }
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

    @Test("Attachments and the media viewer", arguments: Theme.allCases)
    func attachments(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.enterPreview()
        matrix.selectPreviewRoom(PreviewMedia.roomID)
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark

        func capture(_ view: some View, size: CGSize, _ name: String) async throws {
            let hosting = NSHostingView(
                rootView: view.environmentObject(appearance).environment(\.metrics, Metrics()))
            let window = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: .borderless,
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            window.orderFrontRegardless()
            defer {
                window.contentView = nil
                window.close()
            }
            try write(await settledImage(hosting), "\(name)-\(theme.rawValue)")
        }

        let names = [
            "preview.photo": "image", "preview.gif": "gif", "preview.video": "video", "preview.pdf": "pdf",
            "preview.zip": "zip",
        ]
        for message in matrix.messages {
            let row = MessageRow(
                message: message, timeLabel: "10:42 AM", avatar: AvatarView(name: message.senderName),
                attachment: message.attachment.map { AttachmentView(matrix: matrix, message: message, attachment: $0) }
            ).frame(width: 720).fixedSize().background(appearance.colors.canvas)
            let size = NSHostingView(rootView: row.environmentObject(appearance)).fittingSize
            try await capture(row, size: size, "attachment-\(try #require(names[message.id]))")
        }

        let viewer = MediaViewerState()
        viewer.open(matrix.messages[0], surface: .conversation)
        try await capture(
            ZStack {
                RootView(matrix: matrix)
                MediaViewer(matrix: matrix, viewer: viewer, onForward: { _ in })
            }, size: CGSize(width: 1440, height: 900), "viewer")
    }

    @Test("Modals and tab bars", arguments: Theme.allCases)
    func modals(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.enterPreview()
        let room = try #require(matrix.selectedRoom)
        func details(_ tab: RoomInfoView.Tab) -> some View {
            RoomInfoView(
                matrix: matrix, room: room, tab: tab, onClose: {}, onInvite: {}, onRecovery: {},
                onOpenProfile: { _, _ in }, onEditDetails: {}, onNotifications: {})
        }
        let modals: [(String, AnyView)] = [
            (
                "modal-form",
                AnyView(CreationSheet(matrix: matrix, kind: .channel, onCreated: { _, _, _ in }, onClose: {}))
            ),
            (
                "modal-confirm",
                AnyView(
                    ConfirmModal(
                        title: "Leave \(room.name)?", message: "You may need an invitation to rejoin.",
                        action: "Leave", onConfirm: {}, onCancel: {}))
            ),
            ("details-about", AnyView(details(.about))),
            ("details-members", AnyView(details(.members))),
        ]
        for (name, modal) in modals {
            try await render(
                ModalHost { RootView(matrix: matrix).modal(isPresented: .constant(true)) { modal } }, theme: theme,
                name: name
            ) {
                // The sample workspace can't load members and says so in a toast, which would cover the tabs.
                matrix.errorMessage = nil
            }
        }
        try await render(RootView(matrix: matrix), theme: theme, name: "activity") {
            matrix.errorMessage = nil
            NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "activity"])
        }
    }

    /// Borderless, like the other snapshots, but able to take the keyboard.
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    @Test("Jump to, the search menu, search results and People", arguments: Theme.allCases)
    func search(theme: Theme) async throws {
        _ = NSApplication.shared
        UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicsEnabled": false])
        let matrix = MatrixService()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(rootView: RootView(matrix: matrix).environmentObject(appearance))
        let window = KeyWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1440, height: 900), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func press(_ keyCode: UInt16, _ characters: String) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                window.sendEvent(
                    NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!)
            }
        }
        func search(_ text: String) async throws {
            let bar = try #require(
                views(hosting).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Search Harbor" })
            window.makeFirstResponder(bar)
            (window.firstResponder as? NSTextView)?.selectAll(nil)
            window.firstResponder?.insertText(text)
            _ = try await settledImage(hosting)
        }
        let name = theme.rawValue
        _ = try await settledImage(hosting)

        NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "search"])
        try write(await settledImage(hosting), "switcher-empty-\(name)")
        window.firstResponder?.insertText("de")
        try write(await settledImage(hosting), "switcher-query-\(name)")
        press(53, "\u{1b}")
        _ = try await settledImage(hosting)

        try await search("team")
        press(36, "\r")
        try write(await settledImage(hosting), "search-messages-\(name)")
        try await search("te")
        try write(await settledImage(hosting), "search-menu-\(name)")
        try await search("a")
        press(36, "\r")
        _ = try await settledImage(hosting)
        // The People tab, last in the results' tab bar.
        let tab = CGPoint(x: 617, y: 900 - 116)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(
                NSEvent.mouseEvent(
                    with: type, location: tab, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        try write(await settledImage(hosting), "search-people-\(name)")

        NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "people"])
        _ = try await settledImage(hosting)
        window.firstResponder?.insertText("a")
        try write(await settledImage(hosting), "people-\(name)")
    }

    /// The window at 1440 × 900 and 100% with `view` as its content, after `prepare`.
    private func render(
        _ view: some View, theme: Theme, name: String, prepare: () -> Void = {}
    ) async throws {
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(rootView: view.environmentObject(appearance))
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1440, height: 900), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        _ = try await settledImage(hosting)
        prepare()
        try write(await settledImage(hosting), "\(name)-\(theme.rawValue)")
    }

    @Test("Files and the composer's attachment tray", arguments: Theme.allCases)
    func files(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.enterPreview()
        matrix.selectPreviewRoom(PreviewMedia.roomID)
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark

        let files = try ["preview.photo", "preview.gif", "preview.pdf"].map { id in
            try #require(matrix.messages.first { $0.id == id }?.attachment.flatMap(PreviewMedia.file))
        }
        let staged = try await ComposerAttachmentImporter.stage(.files(files), existing: [])
        defer { ComposerAttachmentImporter.discard(staged) }
        let views: [(String, CGSize, AnyView)] = [
            (
                "tray", CGSize(width: 600, height: 200),
                AnyView(
                    MessageComposer(
                        text: .constant(""), placeholder: "Message #design", members: [], onSend: { _, _ in },
                        onTyping: { _ in }, queuedFiles: .constant(staged)
                    ).padding(16))
            ),
            (
                "files", CGSize(width: 900, height: 560),
                AnyView(
                    SharedFilesView(
                        matrix: matrix, service: matrix.sharedFiles, workspaceID: "preview.workspace",
                        onOpen: { _ in }, onOpenMedia: { _, _ in }))
            ),
        ]
        for (name, size, view) in views {
            let hosting = NSHostingView(
                rootView: view.frame(width: size.width).background(appearance.colors.canvas)
                    .environmentObject(appearance))
            let window = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: .borderless,
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            window.orderFrontRegardless()
            defer {
                window.contentView = nil
                window.close()
            }
            try write(await settledImage(hosting), "\(name)-\(theme.rawValue)")
        }
    }

    @Test("Emoji picker, empty and searching", arguments: Theme.allCases)
    func emojiPicker(theme: Theme) async throws {
        let (window, hosting) = try themedWindow(
            PopoverSurface { EmojiPicker(recent: ["👍", "🎉", "✅", "👀", "🙌", "🔥", "🚀", "❤️", "😂", "🙏"]) { _ in } }
                .padding(24),
            theme: theme)
        defer { window.close() }
        try write(await settledImage(hosting), "emoji-picker-\(theme.rawValue)")
        let field = try #require(Self.views(in: hosting).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        window.makeFirstResponder(field)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("heart", replacementRange: editor.selectedRange())
        try write(await settledImage(hosting), "emoji-search-\(theme.rawValue)")
    }

    @Test("A hovered message's toolbar, reactions, replies and (edited)", arguments: Theme.allCases)
    func hoveredRow(theme: Theme) async throws {
        let matrix = MatrixService()
        matrix.enterPreview()
        let room = try #require(matrix.selectedRoom)
        // Signed in rather than sampled, so the toolbar offers reactions.
        matrix.isPreview = false
        matrix.configureMessageActionsForChecks(
            client: FakeClient(rooms: [FakeRoom(roomInfo(id: room.id))]), main: StartOfTimeline(), thread: nil,
            rootID: nil,
            sessionID: UUID(), selectionID: UUID(), threadID: UUID())
        matrix.messages = matrix.messages.map {
            var message = $0
            message.id = "$" + message.id
            return message
        }
        let (window, hosting) = try themedWindow(
            TimelineView(
                matrix: matrix, room: room, savedIDs: [], onThread: { _ in }, onReply: { _ in }, onEdit: { _ in },
                onSave: { _ in }, onForward: { _ in }
            ).environment(Popovers()).frame(width: 760, height: 720),
            theme: theme)
        defer { window.close() }
        _ = try await settledImage(hosting)
        let scroll = try #require(Self.views(in: hosting).compactMap { $0 as? TimelineScrollView }.first)
        let text = try #require(
            Self.views(in: hosting).compactMap { $0 as? MessageTextView }.first { $0.string.hasPrefix("The details") })
        let frame = text.convert(text.bounds, to: nil)
        scroll.onPointer?(NSPoint(x: frame.midX, y: frame.midY))
        try write(await settledImage(hosting), "hovered-row-\(theme.rawValue)")
    }

    @Test("The New line over the first unread message", arguments: Theme.allCases)
    func newLine(theme: Theme) async throws {
        let appearance = AppearanceStore()
        let context = TimelineRowContext()
        context.appearance = appearance
        let message = ChatMessage(
            id: "$new", roomID: "!room:example.org", senderID: "@julia:example.org", senderName: "Julia",
            body: "Pushed the new build, give it a spin", timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        let (window, hosting) = try themedWindow(
            VStack(spacing: 0) {
                TimelineRow(entry: TimelineEntry(id: "unread", kind: .unread), hovered: false, context: context)
                MessageRow(message: message, timeLabel: "10:42 AM")
            }.frame(width: 560),
            theme: theme, appearance: appearance)
        defer { window.close() }
        try write(await settledImage(hosting), "new-line-\(theme.rawValue)")
    }

    /// `view` on the canvas in an offscreen window that the window server composites.
    private func themedWindow(_ view: some View, theme: Theme, appearance: AppearanceStore = AppearanceStore())
        throws -> (NSWindow, NSView)
    {
        _ = NSApplication.shared
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        UserDefaults.standard.set(savedMode, forKey: "appearance.mode")
        let hosting = NSHostingView(
            rootView: view.background(appearance.colors.canvas).environmentObject(appearance)
                .environment(\.colorScheme, theme == .dark ? .dark : .light))
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: hosting.fittingSize),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        return (window, hosting)
    }

    private static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

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
