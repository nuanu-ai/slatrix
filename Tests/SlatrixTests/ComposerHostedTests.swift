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

    private func host(_ view: some View) -> (NSHostingView<AnyView>, NSWindow) {
        let hosting = NSHostingView(rootView: AnyView(view.environmentObject(AppearanceStore())))
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 400), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (hosting, window)
    }

    private func editor(in view: NSView) throws -> NSTextView {
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        return try #require(views(view).compactMap { $0 as? NSTextView }.first { $0.isEditable })
    }

    @Test("A line that wraps grows the composer in the same layout pass")
    func growsWithoutDelay() throws {
        let (hosting, window) = host(Fixture())
        defer {
            window.contentView = nil
            window.close()
        }
        let editor = try editor(in: hosting)
        let scroll = try #require(editor.enclosingScrollView)
        let before = scroll.frame.height
        editor.insertText(
            String(repeating: "A sentence long enough to wrap the composer. ", count: 4),
            replacementRange: editor.selectedRange())
        hosting.layoutSubtreeIfNeeded()
        #expect(scroll.frame.height > before)
    }

    @Test("A mention shows as @Name, the caret never lands inside it, and one Backspace deletes all of it")
    func atomicMention() throws {
        final class Draft { var text = "Hi [Alice](https://matrix.to/#/@alice:example.org) " }
        let draft = Draft()
        let (hosting, window) = host(
            MessageComposer(
                text: Binding(get: { draft.text }, set: { draft.text = $0 }), placeholder: "Message #team",
                members: [], onSend: { _, _ in }, onTyping: { _ in }
            ).frame(width: 360))
        defer {
            window.contentView = nil
            window.close()
        }
        let editor = try editor(in: hosting)
        #expect(editor.string == "Hi @Alice ")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        #expect([3, 9].contains(editor.selectedRange().location))
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        editor.deleteBackward(nil)
        #expect(editor.string == "Hi  " && draft.text == "Hi  ")
    }

    @Test("Staged images show as thumbnails that land without changing the composer's height")
    func trayThumbnailsKeepHeight() async throws {
        let scratch = try TemporaryDirectory()
        let staged = try await ComposerAttachmentImporter.stage(
            .files([
                try scratch.png("wide.png", width: 1_600, height: 900),
                try scratch.png("tall.png", width: 600, height: 1_200), try scratch.file("notes.txt"),
            ]), existing: [])
        defer { ComposerAttachmentImporter.discard(staged) }
        let (hosting, window) = host(
            MessageComposer(
                text: .constant(""), placeholder: "Message #team", members: [], onSend: { _, _ in },
                onTyping: { _ in }, queuedFiles: .constant(staged)
            ).frame(width: 360))
        defer {
            window.contentView = nil
            window.close()
        }
        let before = hosting.fittingSize.height
        #expect(await eventually { showsRed(hosting) })
        #expect(hosting.fittingSize.height == before)
    }

    /// Whether any pixel has the fixture images' red; nothing else in the composer is red.
    private func showsRed(_ view: NSView) -> Bool {
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: image)
        for x in stride(from: 0, to: image.pixelsWide, by: 2) {
            for y in stride(from: 0, to: image.pixelsHigh, by: 2) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.85 && color.greenComponent < 0.3 && color.blueComponent < 0.3 { return true }
            }
        }
        return false
    }
}
