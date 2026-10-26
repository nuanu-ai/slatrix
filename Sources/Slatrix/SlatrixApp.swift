import AppKit
import SwiftUI

@main enum SlatrixEntry {
    @MainActor static func main() {
        Performance.startLaunch()
        Performance.watchMainThread()
        SDKLogging.start()
        SlatrixApp.main()
    }
}

struct SlatrixApp: App {
    @NSApplicationDelegateAdaptor(SlatrixAppDelegate.self) private var appDelegate
    @State private var matrix = MatrixService()
    @StateObject private var appearance = AppearanceStore()
    var body: some Scene {
        Window("Slatrix", id: "main") {
            RootView(matrix: matrix).environmentObject(appearance).environment(\.metrics, metrics)
                .preferredColorScheme(appearance.preferredColorScheme)
                .background(WindowConfiguration(background: NSColor(appearance.colors.frame))).frame(
                    minWidth: minimumSize.width, minHeight: minimumSize.height)
        }
        .windowStyle(.hiddenTitleBar).defaultSize(width: 1440, height: 940)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }.disabled(
                    !AppUpdater.shared.canCheckForUpdates)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") { menuAction("preferences") }.keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) {
                Button("New message") { menuAction("new-message") }.keyboardShortcut("n")
                Button("New channel") { menuAction("new-channel") }.keyboardShortcut(
                    "n", modifiers: [.command, .shift])
                Divider()
                Button("Attach file…") { menuAction("attach") }.keyboardShortcut("u")
            }
            CommandGroup(before: .toolbar) {
                Button("Toggle sidebar") { menuAction("toggle-sidebar") }.keyboardShortcut(
                    "d", modifiers: [.command, .shift])
                Button("Toggle right pane") { menuAction("toggle-pane") }.keyboardShortcut(".")
                Divider()
                Button("Actual Size") { appearance.zoom = 1 }.keyboardShortcut("0")
                Button("Zoom In") { appearance.zoom = AppearanceStore.zoomedIn(appearance.zoom) }
                    .keyboardShortcut("+").disabled(!appearance.canZoomIn)
                Button("Zoom Out") { appearance.zoom = AppearanceStore.zoomedOut(appearance.zoom) }
                    .keyboardShortcut("-").disabled(!appearance.canZoomOut)
                Divider()
            }
            CommandMenu("Go") {
                Button("Jump to…") { menuAction("search") }.keyboardShortcut("k")
                Button("Search…") { menuAction("search-messages") }.keyboardShortcut("g")
                Button("Search in conversation…") { menuAction("search-conversation") }.keyboardShortcut("f")
                Divider()
                Button("Back") { menuAction("back") }.keyboardShortcut("[")
                Button("Forward") { menuAction("forward") }.keyboardShortcut("]")
                Divider()
                Button("Previous conversation") { menuAction("previous-conversation") }.keyboardShortcut(
                    .upArrow, modifiers: [.option])
                Button("Next conversation") { menuAction("next-conversation") }.keyboardShortcut(
                    .downArrow, modifiers: [.option])
                Button("Previous unread conversation") { menuAction("previous-unread") }.keyboardShortcut(
                    .upArrow, modifiers: [.option, .shift])
                Button("Next unread conversation") { menuAction("next-unread") }.keyboardShortcut(
                    .downArrow, modifiers: [.option, .shift])
                Divider()
                Button("Threads") { menuAction("threads") }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Direct messages") { menuAction("dms") }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Activity") { menuAction("activity") }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Later") { menuAction("later") }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("People") { menuAction("people") }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Browse channels") { menuAction("browse-channels") }.keyboardShortcut(
                    "l", modifiers: [.command, .shift])
                Divider()
                // ⌘1–⌘9 switch workspaces in rail order, as in Slack.
                ForEach(
                    Array(
                        WorkspaceRail.entries(workspaces: matrix.workspaces, rooms: matrix.rooms).prefix(9).enumerated()
                    ),
                    id: \.offset
                ) { index, space in
                    Button(space?.name ?? "All conversations") { menuAction("workspace-\(index + 1)") }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
            CommandMenu("Conversation") {
                // Esc and ⇧Esc are routed in SlatrixAppDelegate, so the composer can use Esc first.
                Button("Mark as read") { menuAction("mark-read") }
                Button("Mark all as read") { menuAction("mark-all-read") }
                Divider()
                Button("React to last message…") { menuAction("react-last") }.keyboardShortcut(
                    "\\", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard shortcuts…") { menuAction("shortcuts") }.keyboardShortcut("/")
            }
        }
        #if DEBUG
        Window("Component Gallery", id: "gallery") {
            ScrollView([.vertical, .horizontal]) { ComponentGallery() }.environmentObject(appearance)
                .environment(\.metrics, Metrics()).preferredColorScheme(appearance.preferredColorScheme)
        }
        #endif
    }
    private var metrics: Metrics { Metrics(zoom: appearance.zoom) }
    /// Scales with zoom but never past the screen, so 200% still fits a laptop.
    private var minimumSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: CGFloat.infinity, height: .infinity)
        return CGSize(width: min(metrics(1060), screen.width), height: min(metrics(680), screen.height))
    }
    private func menuAction(_ action: String) {
        NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": action])
    }
}

@MainActor enum SlatrixTermination {
    static var flush: (() async throws -> Void)?
}

@MainActor final class SlatrixAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = PlatformIntegration.shared
        _ = AppUpdater.shared
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { Self.route($0) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Keys a menu item cannot hold. Returns nil for a key it handled.
    private static func route(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // A menu item holds one shortcut, so unshifted ⌘= reaches Zoom In (⌘+) here, as in Slack.
        if modifiers == .command, event.charactersIgnoringModifiers == "=",
            let menu = NSApp.mainMenu?.item(withTitle: "View")?.submenu
        {
            let index = menu.indexOfItem(withTitle: "Zoom In")
            guard index >= 0, menu.items[index].isEnabled else { return event }
            menu.performActionForItem(at: index)
            return nil
        }
        // ⇧⌘\ arrives as ⌘| on most layouts, which the menu item would not match; ⌘F and ⌘G belong to the text
        // system's Find items, which a Slack user expects to search instead.
        let action: String? =
            switch (modifiers, event.charactersIgnoringModifiers) {
            case ([.command, .shift], _) where event.keyCode == 42: "react-last"
            case (.command, "f"): "search-conversation"
            case (.command, "g"): "search-messages"
            default: nil
            }
        if let action, NSApp.keyWindow?.frameAutosaveName == "SlatrixMainWindow" {
            post(action)
            return nil
        }
        // Esc and ⇧Esc mark read from anywhere in the conversation window. Text fields keep Esc (the composer
        // routes it itself once it has nothing to cancel), and so do sheets, popovers and menus.
        guard event.keyCode == 53, modifiers.subtracting(.shift).isEmpty, let window = NSApp.keyWindow,
            window.frameAutosaveName == "SlatrixMainWindow", window.attachedSheet == nil,
            !((window.firstResponder as? NSTextView)?.isEditable ?? false)
        else { return event }
        post(modifiers.contains(.shift) ? "mark-all-read" : "mark-read")
        return nil
    }
    private static func post(_ action: String) {
        NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": action])
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let flush = SlatrixTermination.flush else { return .terminateNow }
        Task {
            do {
                try await flush()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t save your drafts"
                alert.informativeText = "Copy your draft or quit again. " + MatrixService.safeError(error)
                alert.addButton(withTitle: "OK")
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
}
