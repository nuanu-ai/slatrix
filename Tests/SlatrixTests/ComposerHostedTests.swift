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
        let window = offscreenWindow(NSSize(width: 400, height: 400))
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
        let draft = Draft("Hi <a href=\"https://matrix.to/#/@alice:example.org\">Alice</a> there")
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
        #expect(editor.string == "Hi @Alice there")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        #expect([3, 9].contains(editor.selectedRange().location))
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        editor.deleteBackward(nil)
        #expect(editor.string == "Hi  there" && !draft.text.contains("<a"))
    }

    // MARK: Formatting

    /// What the composer last wrote to its binding, and how often it asked to send.
    final class Draft {
        var text: String
        var sends = 0
        init(_ text: String = "") { self.text = text }
    }

    private func composer(_ draft: Draft, members: [ChatUser] = []) throws -> (NSTextView, NSWindow) {
        let (hosting, window) = host(
            MessageComposer(
                text: Binding(get: { draft.text }, set: { draft.text = $0 }), placeholder: "Message #team",
                members: members, onSend: { _, _ in draft.sends += 1 }, onTyping: { _ in }
            ).frame(width: 360))
        let editor = try editor(in: hosting)
        window.makeFirstResponder(editor)
        return (editor, window)
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    /// A key as the keyboard sends it: `characters` is what the key types without modifiers.
    private func press(
        _ editor: NSTextView, _ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []
    ) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: editor.window?.windowNumber ?? 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        if modifiers.contains(.command) {
            #expect(editor.performKeyEquivalent(with: event))
        } else {
            editor.keyDown(with: event)
        }
    }

    private func type(_ editor: NSTextView, _ text: String) {
        for character in text {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    @Test("A two-word name keeps the @ list open, and Return mentions the person instead of sending")
    func mentionAcrossSpace() throws {
        let draft = Draft()
        let members = [
            ChatUser(id: "@aisha:example.org", name: "Aisha Khan"),
            ChatUser(id: "@agent:example.org", name: "AI Agent"),
        ]
        let (editor, window) = try composer(draft, members: members)
        defer { close(window) }
        type(editor, "@AI A")
        try press(editor, "\r", 36)
        #expect(editor.string == "@AI Agent ")
        #expect(draft.text.contains("https://matrix.to/#/@agent:example.org") && draft.sends == 0)
    }

    @Test(
        "Each shortcut formats the selection as Slack's does",
        arguments: [
            ("b", 11, [.command], "<strong>word</strong>"), ("i", 34, [.command], "<em>word</em>"),
            ("x", 7, [.command, .shift], "<del>word</del>"), ("c", 8, [.command, .shift], "<code>word</code>"),
            ("c", 8, [.command, .shift, .option], "<pre><code>word</code></pre>"),
            ("7", 26, [.command, .shift], "<ol><li>word</li></ol>"),
            ("8", 28, [.command, .shift], "<ul><li>word</li></ul>"),
            ("9", 25, [.command, .shift], "<blockquote>word</blockquote>"),
        ] as [(String, UInt16, NSEvent.ModifierFlags, String)])
    func shortcuts(key: String, code: UInt16, modifiers: NSEvent.ModifierFlags, html: String) throws {
        let draft = Draft("word")
        let (editor, window) = try composer(draft)
        defer { close(window) }
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        try press(editor, key, code, modifiers)
        #expect(editor.string == "word")
        #expect(draft.text == html)
    }

    @Test("Bold goes on a selection and off again, and at the caret applies to what is typed next")
    func toggles() throws {
        let draft = Draft()
        let (editor, window) = try composer(draft)
        defer { close(window) }
        type(editor, "Hello world")
        editor.setSelectedRange(NSRange(location: 6, length: 5))
        try press(editor, "b", 11, .command)
        #expect(draft.text == "Hello <strong>world</strong>")
        try press(editor, "b", 11, .command)
        #expect(draft.text == "Hello world")
        editor.setSelectedRange(NSRange(location: 11, length: 0))
        try press(editor, "b", 11, .command)
        type(editor, "!")
        try press(editor, "b", 11, .command)
        type(editor, "?")
        #expect(draft.text == "Hello world<strong>!</strong>?")
    }

    @Test(
        "Return continues a list or quote, and Return on its empty line ends it without sending",
        arguments: [
            ("8", 28 as UInt16, "<ul><li>one</li><li>two</li></ul>after"),
            ("9", 25 as UInt16, "<blockquote>one<br>two</blockquote>after"),
        ])
    func returnInBlocks(key: String, code: UInt16, html: String) async throws {
        let draft = Draft()
        let (editor, window) = try composer(draft)
        defer { close(window) }
        try press(editor, key, code, [.command, .shift])
        type(editor, "one")
        try press(editor, "\r", 36)
        type(editor, "two")
        try press(editor, "\r", 36)
        try press(editor, "\r", 36)
        type(editor, "after")
        #expect(editor.string == "one\ntwo\nafter")
        #expect(draft.text == html)
        #expect(draft.sends == 0)
        try press(editor, "\r", 36)
        #expect(await eventually { draft.sends == 1 })
    }

    @Test("Undo takes formatting off again, and redo puts it back")
    func undo() throws {
        let draft = Draft("Hello world")
        let (editor, window) = try composer(draft)
        defer { close(window) }
        let undo = try #require(editor.undoManager)
        editor.setSelectedRange(NSRange(location: 6, length: 5))
        try press(editor, "b", 11, .command)
        undo.undo()
        #expect(draft.text == "Hello world")
        undo.redo()
        #expect(draft.text == "Hello <strong>world</strong>")
        try press(editor, "8", 28, [.command, .shift])
        #expect(draft.text == "<ul><li>Hello <strong>world</strong></li></ul>")
        undo.undo()
        #expect(draft.text == "Hello <strong>world</strong>")
    }

    @Test(
        "Slack's markup at the start of a line becomes the block it stands for",
        arguments: [
            ("- ", "<ul><li>item</li></ul>"), ("1. ", "<ol><li>item</li></ol>"),
            ("> ", "<blockquote>item</blockquote>"),
            ("```", "<pre><code>item</code></pre>"),
        ])
    func markup(markup: String, html: String) throws {
        let draft = Draft()
        let (editor, window) = try composer(draft)
        defer { close(window) }
        type(editor, markup + "item")
        #expect(editor.string == "item")
        #expect(draft.text == html)
    }

    @Test("A message opened for editing shows its formatting with no markup, and saves it unchanged")
    func editingLoadsFormatting() throws {
        let html = "Hi <strong>there</strong><blockquote>quoted</blockquote><ol><li>one</li><li>two</li></ol>"
        let draft = Draft(html)
        let (editor, window) = try composer(draft)
        defer { close(window) }
        #expect(editor.string == "Hi there\nquoted\none\ntwo")
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        type(editor, "!")
        #expect(
            draft.text == "Hi <strong>there</strong><blockquote>quoted</blockquote><ol><li>one</li><li>two!</li></ol>")
    }

    @Test("Text composed through an input method takes the formatting on at the caret")
    func inputMethod() throws {
        let draft = Draft()
        let (editor, window) = try composer(draft)
        defer { close(window) }
        try press(editor, "b", 11, .command)
        editor.setMarkedText(
            "にほん", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "日本" && !editor.hasMarkedText())
        #expect(draft.text == "<strong>日本</strong>")
    }

    @Test("Pasted rich text keeps bold, links and lists, and drops colors and fonts")
    func pasteRichText() throws {
        let draft = Draft()
        let (editor, window) = try composer(draft)
        defer { close(window) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("slatrix-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString(
            "<meta charset='utf-8'><p style='font-family:Georgia'>Hi <b>bold</b> <span style='color:red'>red</span> "
                + "<a href='https://example.org'>site</a></p><ul><li>x</li></ul>", forType: .html)
        pasteboard.setString("Hi bold red site\nx", forType: .string)
        #expect(editor.readSelection(from: pasteboard))
        #expect(
            draft.text
                == "Hi <strong>bold</strong> red <a href=\"https://example.org\">site</a><ul><li>x</li></ul>")
    }

    @Test("A composer cleared while in a list, as by sending or switching rooms, starts plain")
    func clearedStartsPlain() throws {
        final class Model: ObservableObject { @Published var text = "" }
        struct Observed: View {
            @ObservedObject var model: Model
            var body: some View {
                MessageComposer(
                    text: $model.text, placeholder: "Message #team", members: [], onSend: { _, _ in },
                    onTyping: { _ in }
                ).frame(width: 360)
            }
        }
        let model = Model()
        let (hosting, window) = host(Observed(model: model))
        defer { close(window) }
        let editor = try editor(in: hosting)
        window.makeFirstResponder(editor)
        try press(editor, "8", 28, [.command, .shift])
        type(editor, "item")
        #expect(model.text == "<ul><li>item</li></ul>")
        model.text = ""
        hosting.layoutSubtreeIfNeeded()
        type(editor, "next")
        #expect(model.text == "next")
    }

    @Test("Pasted HTML with markup a message can't carry arrives as its plain text")
    func pasteUnsupportedHTML() throws {
        let draft = Draft()
        let (editor, window) = try composer(draft)
        defer { close(window) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("slatrix-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString(
            "<section>\n  <h2>Title</h2>\n  <p>Body <sup>1</sup></p>\n</section>\n<style>p { color: red }</style>",
            forType: .html)
        pasteboard.setString("Title\nBody 1", forType: .string)
        #expect(editor.readSelection(from: pasteboard))
        #expect(editor.string == "Title\nBody 1")
    }

    @Test("An empty list item starts its text after the bullet")
    func emptyListItem() throws {
        let draft = Draft()
        let (editor, window) = try composer(draft)
        defer { close(window) }
        try press(editor, "8", 28, [.command, .shift])
        let layout = try #require(editor.layoutManager)
        layout.ensureLayout(for: try #require(editor.textContainer))
        #expect(layout.extraLineFragmentUsedRect.minX >= MessageBlocks.listIndent(13))
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
