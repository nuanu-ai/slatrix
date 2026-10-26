import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// The composer in a real offscreen window; opt-in like the timeline's hosted tests.
@MainActor
@Suite(.tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct ComposerHostedTests {
    private struct Fixture: View {
        @State var text = ""
        var body: some View {
            MessageComposer(
                text: $text, placeholder: "Message #team", members: [], onSend: { _, _ in }, onTyping: { _ in }
            )
            .frame(width: 360)
        }
    }

    @Test("A line that wraps grows the composer in the same layout pass")
    func growsWithoutDelay() throws {
        let hosting = NSHostingView(rootView: Fixture().environmentObject(AppearanceStore()))
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 400), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        hosting.layoutSubtreeIfNeeded()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let editor = try #require(views(hosting).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        let scroll = try #require(editor.enclosingScrollView)
        let before = scroll.frame.height
        editor.insertText(
            String(repeating: "A sentence long enough to wrap the composer. ", count: 4),
            replacementRange: editor.selectedRange())
        hosting.layoutSubtreeIfNeeded()
        #expect(scroll.frame.height > before)
    }
}
