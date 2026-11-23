import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// The composer in a real offscreen window; opt-in like the timeline's hosted tests. One at a time: a window that says
/// it is key takes text editing from the others.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
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

    private func host(_ view: some View, key: Bool = false) -> (NSHostingView<AnyView>, NSWindow) {
        let hosting = NSHostingView(rootView: AnyView(view.environmentObject(AppearanceStore())))
        let window = offscreenWindow(NSSize(width: 400, height: 400), key: key)
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

    @Test("The caret stays where the edit was beside a mention, in a code block, and when paragraphs join")
    func caretStaysAtEdit() throws {
        let typed = NSRange(location: NSNotFound, length: 0)
        let mention = "<a href=\"https://matrix.to/#/@alice:example.org\">Alice</a>"
        for (draft, at, edit, caret) in [
            ("Fix this<br>Hi \(mention)", 0, "x", 1), ("<pre><code>abc def</code></pre>", 1, "x", 2),
            ("<ul><li>one</li></ul>plain", 4, "", 3),
        ] {
            let draft = Draft(draft)
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
            editor.setSelectedRange(NSRange(location: at, length: 0))
            if edit.isEmpty { editor.deleteBackward(nil) } else { editor.insertText(edit, replacementRange: typed) }
            #expect(editor.selectedRange() == NSRange(location: caret, length: 0), "\(draft.text)")
        }
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

    // capability: composer.formatting
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

    @MainActor private final class Cover: ObservableObject { @Published var covered = false }

    /// A composer that a pane can cover, beside a field the keyboard can go to instead, like a thread's reply.
    private struct Covered: View {
        @ObservedObject var cover: Cover
        let sent: Gate
        var editing = false
        @State private var text = ""
        @State private var other = ""
        var body: some View {
            VStack {
                MessageComposer(
                    text: $text, placeholder: "Message #team", members: [], isEditing: editing,
                    onSend: { _, _ in await sent.wait() }, onTyping: { _ in }
                ).covered(cover.covered)
                TextField("Reply…", text: $other)
            }.frame(width: 360)
        }
    }

    @Test("A send that finishes once the composer is covered leaves the keyboard where it went meanwhile")
    func coveredSendKeepsFocus() async throws {
        let cover = Cover()
        let sent = Gate()
        sent.arm()
        let (hosting, window) = host(Covered(cover: cover, sent: sent))
        defer {
            window.contentView = nil
            window.close()
        }
        let editor = try editor(in: hosting)
        window.makeFirstResponder(editor)
        editor.insertText("Hello", replacementRange: editor.selectedRange())
        editor.keyDown(
            with: try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
        #expect(await eventually { sent.isWaiting })

        cover.covered = true
        hosting.layoutSubtreeIfNeeded()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let reply = try #require(views(hosting).first { ($0 as? NSTextField)?.placeholderString == "Reply…" })
        #expect(window.makeFirstResponder(reply))
        let focused = window.firstResponder
        sent.release()
        #expect(await eventually { editor.string.isEmpty })
        await drainMainActor()
        #expect(window.firstResponder === focused && focused !== editor)
    }

    @Test("An edit uncovered doesn't take back the keyboard that went elsewhere meanwhile")
    func uncoveredEditKeepsFocus() async throws {
        let cover = Cover()
        let (hosting, window) = host(Covered(cover: cover, sent: Gate(), editing: true), key: true)
        defer {
            window.contentView = nil
            window.close()
        }
        let editor = try editor(in: hosting)
        // An edit takes the keyboard as it opens.
        #expect(await eventually { window.firstResponder === editor })

        cover.covered = true
        hosting.layoutSubtreeIfNeeded()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let reply = try #require(views(hosting).first { ($0 as? NSTextField)?.placeholderString == "Reply…" })
        #expect(await eventually { window.firstResponder !== editor })
        #expect(window.makeFirstResponder(reply))
        cover.covered = false
        hosting.layoutSubtreeIfNeeded()
        // Only the editor: a test window in parallel can take key and end the reply's editing.
        #expect(await !eventually(timeout: .milliseconds(500)) { window.firstResponder === editor })
    }

    // AppKit reads `isEditable` before it lets a drop, a paste or a service put text in.
    @Test("A covered composer takes no dropped text, and takes it again once uncovered")
    func coveredTakesNoDrop() throws {
        let cover = Cover()
        let (hosting, window) = host(Covered(cover: cover, sent: Gate()))
        defer {
            window.contentView = nil
            window.close()
        }
        let editor = try editor(in: hosting)
        cover.covered = true
        hosting.layoutSubtreeIfNeeded()
        #expect(!editor.isEditable)
        cover.covered = false
        hosting.layoutSubtreeIfNeeded()
        #expect(editor.isEditable)
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

    @Test("The composer matches the timeline's line spacing and text ink color")
    func matchesTimelineTypography() throws {
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        let savedTheme = UserDefaults.standard.object(forKey: "appearance.theme")
        defer {
            UserDefaults.standard.set(savedMode, forKey: "appearance.mode")
            UserDefaults.standard.set(savedTheme, forKey: "appearance.theme")
        }
        let appearance = AppearanceStore()
        appearance.mode = .light
        appearance.theme = .sand
        let draft = Draft("First line<br>Second line")
        let m = Metrics(zoom: 1)
        let hosting = NSHostingView(
            rootView: AnyView(
                MessageComposer(
                    text: Binding(get: { draft.text }, set: { draft.text = $0 }), placeholder: "Message #team",
                    members: [], onSend: { _, _ in }, onTyping: { _ in }
                ).frame(width: 360).environmentObject(appearance).environment(\.metrics, m)))
        let window = offscreenWindow(NSSize(width: 400, height: 400))
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let view = try editor(in: hosting)
        let attrs = try #require(view.textStorage?.attributes(at: 0, effectiveRange: nil))
        let paragraph = try #require(attrs[.paragraphStyle] as? NSParagraphStyle)
        let font = try #require(attrs[.font] as? NSFont)
        #expect(
            abs(font.pointSize - m.size(.reading)) < 0.1, "composer=\(font.pointSize) vs reading=\(m.size(.reading))")
        let timeline = NativeSelectableMessageText.attributed(
            [MessageBodyRun(text: "First line\nSecond line")], fontSize: Double(m.size(.reading)),
            textColor: NSColor(appearance.colors.textBody), linkColor: NSColor(appearance.colors.accent))
        let timelineParagraph = try #require(
            timeline.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(
            abs(paragraph.lineSpacing - timelineParagraph.lineSpacing) < 0.1,
            "composer=\(paragraph.lineSpacing) vs timeline=\(timelineParagraph.lineSpacing)")
        let ink = try #require((attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB))
        let expected = try #require(NSColor(appearance.colors.textBody).usingColorSpace(.sRGB))
        #expect(
            abs(ink.redComponent - expected.redComponent) < 0.02
                && abs(ink.greenComponent - expected.greenComponent) < 0.02
                && abs(ink.blueComponent - expected.blueComponent) < 0.02,
            "Expected theme textBody ink, got \(ink) vs \(expected)")
    }

    @Test("The formatting toggle opens the formatting bar without requiring a text selection")
    func persistentFormattingToggle() async throws {
        _ = NSApplication.shared
        VoiceOver.listen()
        defer { VoiceOver.done() }
        let (hosting, window) = host(Fixture())
        defer { close(window) }
        #expect(await eventually { !accessible("Formatting", in: hosting).isEmpty })
        let toggle = try #require(accessible("Formatting", in: hosting).first)
        #expect(accessible("Bold", in: hosting).isEmpty)
        _ = toggle.accessibilityPerformPress?()
        #expect(await eventually { !accessible("Bold", in: hosting).isEmpty })
    }

    @Test("The inline formatting bar fits within the minimum 248 pt thread composer width without overflowing")
    func inlineFormattingBarFitsMinimumThreadWidth() async throws {
        _ = NSApplication.shared
        VoiceOver.listen()
        defer { VoiceOver.done() }
        let draft = Draft()
        let (hosting, window) = host(
            MessageComposer(
                text: Binding(get: { draft.text }, set: { draft.text = $0 }), placeholder: "Reply",
                members: [], onSend: { _, _ in }, onTyping: { _ in }
            ).frame(width: 248))
        defer { close(window) }
        #expect(await eventually { !accessible("Formatting", in: hosting).isEmpty })
        let toggle = try #require(accessible("Formatting", in: hosting).first)
        _ = toggle.accessibilityPerformPress?()
        #expect(await eventually { !accessible("Bold", in: hosting).isEmpty })
        hosting.layoutSubtreeIfNeeded()
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let editorScroll = try editor(in: hosting).enclosingScrollView
        let barScroll = try #require(
            allViews(hosting).compactMap { $0 as? NSScrollView }.first { $0 !== editorScroll })
        let barFrame = barScroll.convert(barScroll.bounds, to: hosting)
        let composerLeft = (hosting.bounds.width - 248) / 2
        let composerRight = composerLeft + 248
        #expect(
            barFrame.width <= 248.5 && barFrame.minX >= composerLeft - 0.5 && barFrame.maxX <= composerRight + 0.5,
            "Formatting bar ScrollView overflowed 248 pt composer: \(barFrame) vs [\(composerLeft), \(composerRight)]")
        #expect(
            hosting.fittingSize.width <= 248.5,
            "Inline formatting bar overflowed 248 pt thread width: \(hosting.fittingSize.width)")
    }

    @Test("Disabling composer input leaves reply Retry and Cancel buttons interactive")
    func disabledInputKeepsReplyAccessoriesInteractive() async throws {
        _ = NSApplication.shared
        VoiceOver.listen()
        defer { VoiceOver.done() }
        let draft = Draft()
        var retried = false
        var cancelled = false
        let (hosting, window) = host(
            VStack {
                Spacer()
                MessageComposer(
                    text: Binding(get: { draft.text }, set: { draft.text = $0 }), placeholder: "Reply",
                    members: [], onSend: { _, _ in }, onTyping: { _ in }, inputDisabled: true,
                    accessories: AnyView(
                        HStack {
                            Button("Retry") { retried = true }.buttonStyle(.textLink)
                            Button("Cancel reply") { cancelled = true }.buttonStyle(.row)
                        }.frame(maxWidth: .infinity, minHeight: 36)))
            }.frame(width: 360, height: 320))
        defer { close(window) }
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let view = try #require(allViews(hosting).compactMap { $0 as? NSTextView }.first)
        #expect(!view.isEditable)
        #expect(await eventually { !accessible("Retry", in: hosting).isEmpty })
        let retry = try #require(accessible("Retry", in: hosting).first)
        let cancel = try #require(accessible("Cancel reply", in: hosting).first)
        #expect(retry.isAccessibilityEnabled?() == true)
        #expect(cancel.isAccessibilityEnabled?() == true)
        _ = retry.accessibilityPerformPress?()
        _ = cancel.accessibilityPerformPress?()
        #expect(await eventually { retried && cancelled })
    }

    @Test("Jump to recent stays above floating composer accessories without overlapping them")
    func jumpToRecentClearsComposerAccessories() async throws {
        _ = NSApplication.shared
        VoiceOver.listen()
        defer { VoiceOver.done() }
        let matrix = MatrixService.scratch()
        let room = ChatRoom(id: "!jump:example.org", name: "general")
        let messages = (0..<6).map { i in
            ChatMessage(
                id: "$m\(i)", roomID: room.id, senderID: "@alice:example.org", senderName: "Alice",
                body: "Message \(i)", timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60))
        }
        matrix.rooms = [room]
        matrix.selectedRoomID = room.id
        matrix.messages = messages
        matrix.focusedEventID = messages.first?.id
        let draft = Draft()
        let members = [
            ChatUser(id: "@alice:example.org", name: "Alice"),
            ChatUser(id: "@alex:example.org", name: "Alex"),
        ]
        let (hosting, window) = host(
            TimelineUnderBars { insets in
                TimelineView(
                    matrix: matrix, room: room, savedIDs: [], onThread: { _ in }, onReply: { _ in }, onEdit: { _ in },
                    onSave: { _ in }, insets: insets)
            } header: {
                Color.clear.frame(height: 44)
            } footer: {
                MessageComposer(
                    text: Binding(get: { draft.text }, set: { draft.text = $0 }), placeholder: "Message #general",
                    members: members, onSend: { _, _ in }, onTyping: { _ in },
                    accessories: AnyView(
                        HStack {
                            Text("Replying to Alice")
                            Spacer()
                            Button("Cancel reply") {}.buttonStyle(.row)
                        }.frame(maxWidth: .infinity, minHeight: 44))
                ).conversationRow(Metrics(zoom: 1), isThread: false)
            }
            .frame(width: 900, height: 500))
        defer { close(window) }
        #expect(
            await eventually(timeout: .seconds(10)) {
                !accessible("Jump to recent", in: hosting).isEmpty && !accessible("Cancel reply", in: hosting).isEmpty
            })
        let jump = try #require(accessible("Jump to recent", in: hosting).first)
        let banner = try #require(accessible("Cancel reply", in: hosting).first)
        #expect(
            await eventually(timeout: .seconds(5)) {
                let jumpFrame = jump.accessibilityFrame?() ?? .zero
                let bannerFrame = banner.accessibilityFrame?() ?? .zero
                return !jumpFrame.isEmpty && !bannerFrame.isEmpty && !jumpFrame.intersects(bannerFrame)
                    && jumpFrame.minY >= bannerFrame.maxY - 1
            })
        // Opening mention suggestions above the banner lifts Jump to recent above the whole floating stack too.
        let view = try editor(in: hosting)
        window.makeFirstResponder(view)
        type(view, "@Al")
        #expect(await eventually(timeout: .seconds(5)) { !accessible("Alice", in: hosting).isEmpty })
        let suggestion = try #require(accessible("Alice", in: hosting).first)
        #expect(
            await eventually(timeout: .seconds(5)) {
                let jumpFrame = jump.accessibilityFrame?() ?? .zero
                let suggestionFrame = suggestion.accessibilityFrame?() ?? .zero
                return !jumpFrame.isEmpty && !suggestionFrame.isEmpty && !jumpFrame.intersects(suggestionFrame)
                    && jumpFrame.minY >= suggestionFrame.maxY - 1
            })
    }

    @Test("Mention suggestions stack cleanly above RootView composer banners without overlapping")
    func overlaysNeverCollide() async throws {
        _ = NSApplication.shared
        VoiceOver.listen()
        defer { VoiceOver.done() }
        let local = try TemporaryDirectory()
        let sample = local.url.appendingPathComponent("report.txt")
        try Data("hello".utf8).write(to: sample)
        let vaultKey: @Sendable (String) async throws -> Data = { _ in Data(repeating: 0x5a, count: 32) }
        let store = ProtectedLocalStateStore(directory: local.url, keyProvider: vaultKey)
        let files = AttachmentDraftStore(
            directory: AttachmentDraftStore.directory(in: local.url), keyProvider: vaultKey)
        let room = FakeOpenRoom("!overlay:example.org", cached: [])
        room.memberList = [
            roomMember("@alice:example.org", name: "Alice"),
            roomMember("@alex:example.org", name: "Alex"),
        ]
        let address = AttachmentDraftAddress(roomID: room.id())
        let access = try await files.open(accountID: "@me:example.org")
        _ = try await files.save(urls: [sample], address: address, access: access, revision: 1)
        try await files.markSending(url: sample, address: address, access: access, revision: 2)
        await files.close(access: access)

        let matrix = MatrixService.scratch()
        matrix.configureRoomOpenForChecks(
            client: FakeClient(rooms: [room]), roomList: FakeRoomListService(),
            user: ChatUser(id: "@me:example.org", name: "Me"))
        matrix.status = .ready
        matrix.rooms = [ChatRoom(id: room.id(), name: "team")]
        matrix.roomsLoaded = true
        UserDefaults.standard.removeObject(forKey: "room.@me:example.org")
        let hosting = NSHostingView(
            rootView: AnyView(
                RootView(matrix: matrix, localStore: store, attachmentDrafts: files)
                    .environmentObject(AppearanceStore())
                    .environment(\.metrics, Metrics(zoom: 1))))
        let window = offscreenWindow(NSSize(width: 1_000, height: 700), key: true)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { close(window) }

        await matrix.selectRoom(room.id())
        #expect(
            await eventually(timeout: .seconds(10)) {
                hosting.layoutSubtreeIfNeeded()
                return matrix.members.count == 2 && !accessible("Send anyway", in: hosting).isEmpty
                    && (try? editor(in: hosting).isEditable) == true
            })
        let view = try editor(in: hosting)
        window.makeFirstResponder(view)
        type(view, "@Al")
        #expect(await eventually(timeout: .seconds(5)) { !accessible("Alice", in: hosting).isEmpty })
        let banner = try #require(accessible("Send anyway", in: hosting).first)
        let suggestion = try #require(accessible("Alice", in: hosting).first)
        let bannerFrame = banner.accessibilityFrame?() ?? .zero
        let suggestionFrame = suggestion.accessibilityFrame?() ?? .zero
        #expect(!bannerFrame.isEmpty && !suggestionFrame.isEmpty)
        #expect(
            !bannerFrame.intersects(suggestionFrame), "banner=\(bannerFrame) overlaps suggestion=\(suggestionFrame)")
        #expect(suggestionFrame.minY >= bannerFrame.maxY - 1, "suggestion=\(suggestionFrame) banner=\(bannerFrame)")

        // Losing posting permission replaces the composer with ComposerNotice while keeping draft recovery reachable.
        matrix.rooms[0].canPostMessages = false
        #expect(await eventually(timeout: .seconds(5)) { !accessible("Send anyway", in: hosting).isEmpty })
    }
}
