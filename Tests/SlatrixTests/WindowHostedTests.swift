import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// The whole window in a real offscreen window, with a busy conversation open; needs an awake display.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct WindowHostedTests {
    @MainActor private final class Harness {
        let matrix = MatrixService()
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
        let messages: [ChatMessage]

        init() {
            _ = NSApplication.shared
            matrix.enterPreview()
            messages = busyConversation(1_000, roomID: matrix.selectedRoomID!, tag: UUID().uuidString)
            matrix.messages = messages
            hosting = NSHostingView(rootView: AnyView(RootView(matrix: matrix).environmentObject(AppearanceStore())))
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 1_440, height: 900), styleMask: .borderless,
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
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
        #expect(time < .milliseconds(100), "\(time)")
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
        #expect(time < .milliseconds(100), "\(time)")
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
        #expect(time < .milliseconds(100), "\(time)")
    }
}
