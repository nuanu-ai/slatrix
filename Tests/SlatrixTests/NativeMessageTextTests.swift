import AppKit
import Testing

@testable import Slatrix

@MainActor
struct NativeMessageTextTests {
    private let link = URL(string: "https://example.org/message")!
    private var text: NSAttributedString {
        NativeSelectableMessageText.attributed(
            [
                MessageBodyRun(text: "Bold", style: .bold), MessageBodyRun(text: "Italic", style: .italic),
                MessageBodyRun(text: "Code", style: [.bold, .code]),
                MessageBodyRun(text: "Strike", style: [.strike, .underline]), MessageBodyRun(text: "Link", link: link),
                MessageBodyRun(text: "Unsafe", link: URL(string: "file:///private/fixture")),
                MessageBodyRun(text: "\n› Quote\n• Item"),
            ], fontSize: 15, textColor: .labelColor, linkColor: .systemBlue)
    }
    private func traits(at position: Int) -> NSFontDescriptor.SymbolicTraits? {
        (text.attribute(.font, at: position, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits
    }

    @Test("Run text, including quotes and list markers, is kept as is")
    func keepsText() {
        #expect(text.string == "BoldItalicCodeStrikeLinkUnsafe\n› Quote\n• Item")
    }

    @Test("Bold and italic runs get bold and italic fonts")
    func emphasis() {
        #expect(traits(at: 0)?.contains(.bold) == true)
        #expect(traits(at: 4)?.contains(.italic) == true)
    }

    @Test("Code is monospaced on a background and keeps nested bold")
    func code() {
        #expect(traits(at: 10)?.contains(.monoSpace) == true)
        #expect(traits(at: 10)?.contains(.bold) == true)
        #expect(text.attribute(.backgroundColor, at: 10, effectiveRange: nil) is NSColor)
    }

    @Test("Strikethrough and underline are both applied")
    func strikeAndUnderline() {
        #expect(text.attribute(.strikethroughStyle, at: 14, effectiveRange: nil) as? Int == 1)
        #expect(text.attribute(.underlineStyle, at: 14, effectiveRange: nil) as? Int == 1)
    }

    @Test("A safe link is clickable and a file link is not")
    func links() {
        #expect(text.attribute(.link, at: 20, effectiveRange: nil) as? URL == link)
        #expect(text.attribute(.link, at: 24, effectiveRange: nil) == nil)
    }

    @Test("A mention of someone else is a blue pill; one of you, or of the room, is yellow; none is underlined")
    func mentionPills() {
        let profile = URL(string: "https://matrix.to/#/@alice:example.org")!
        let pills = MentionPalette(
            me: "@me:example.org", text: .systemBlue, fill: .systemTeal, ownText: .systemBrown, ownFill: .systemYellow)
        let text = NativeSelectableMessageText.attributed(
            [
                MessageBodyRun(text: "@Alice", link: profile, mention: "@alice:example.org"),
                MessageBodyRun(text: " "), MessageBodyRun(text: "@Me", mention: "@me:example.org"),
                MessageBodyRun(text: " "), MessageBodyRun(text: "@room", mention: "@room"),
            ], fontSize: 15, textColor: .labelColor, linkColor: .systemBlue, mentions: pills)
        #expect(text.attribute(.mentionPill, at: 0, effectiveRange: nil) as? NSColor == .systemTeal)
        #expect(text.attribute(.mentionPill, at: 7, effectiveRange: nil) as? NSColor == .systemYellow)
        #expect(text.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor == .systemBrown)
        #expect(text.attribute(.mentionPill, at: 11, effectiveRange: nil) as? NSColor == .systemYellow)
        #expect(text.attribute(.mentionPill, at: 6, effectiveRange: nil) == nil)
        #expect(text.attribute(.link, at: 0, effectiveRange: nil) as? URL == profile)
        #expect(text.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil)
    }

    private func style(_ text: NSAttributedString, at index: Int) -> NSParagraphStyle? {
        text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }

    /// Where the glyph for `character` lands once `text` is laid out `width` points wide.
    private func positions(_ text: NSAttributedString, width: CGFloat) -> (Int) -> NSPoint {
        let storage = NSTextStorage(attributedString: text)
        let layout = PillLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return { character in
            _ = storage  // A layout manager holds its storage weakly.
            let glyph = layout.glyphIndexForCharacter(at: character)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return NSPoint(x: line.minX + layout.location(forGlyphAt: glyph).x, y: line.minY)
        }
    }

    @Test("A quote indents past its bar, and the text after it does not")
    func quoteLayout() {
        let text = NativeSelectableMessageText.attributed(
            [MessageBodyRun(text: "said\nthis\n", block: MessageBlock(quote: 1)), MessageBodyRun(text: "after")],
            fontSize: 15, textColor: .labelColor, linkColor: .systemBlue)
        let at = positions(text, width: 400)
        #expect(at(0).x >= MessageBlocks.barWidth(15) * 2 && at(5).x == at(0).x)
        #expect(text.attribute(.quoteBar, at: 9, effectiveRange: nil) is NSColor)
        #expect(at(10).x == 0 && text.attribute(.quoteBar, at: 10, effectiveRange: nil) == nil)
    }

    @Test("A list item's wrapped lines start under its first word, not under its marker")
    func listLayout() throws {
        let item = String(repeating: "word ", count: 30)
        let text = NativeSelectableMessageText.attributed(
            [
                MessageBodyRun(text: "• ", block: MessageBlock(list: 1), marker: true),
                MessageBodyRun(text: item, block: MessageBlock(list: 1)),
            ], fontSize: 15, textColor: .labelColor, linkColor: .systemBlue)
        let at = positions(text, width: 200)
        let wrapped = try #require((2..<text.length).first { at($0).y > at(2).y })
        #expect(at(0).x == 0 && at(2).x > 0)
        #expect(abs(at(wrapped).x - at(2).x) < 0.5)
    }

    @Test("A code block sits on a padded fill instead of inline code's background")
    func codeBlockLayout() {
        let text = NativeSelectableMessageText.attributed(
            [
                MessageBodyRun(text: "before\n"),
                MessageBodyRun(text: "let x\nlet y\n", style: .code, block: MessageBlock(code: true)),
                MessageBodyRun(text: "after"),
            ], fontSize: 15, textColor: .labelColor, linkColor: .systemBlue)
        let at = positions(text, width: 400)
        #expect(text.attribute(.codeBlock, at: 7, effectiveRange: nil) is NSColor)
        #expect(text.attribute(.backgroundColor, at: 7, effectiveRange: nil) == nil)
        #expect(at(7).x > 0 && at(13).x == at(7).x && at(19).x == 0)
        // Padding above the first line and below the last, none between them.
        #expect((style(text, at: 7)?.paragraphSpacingBefore ?? 0) > 0 && style(text, at: 7)?.paragraphSpacing == 0)
        #expect(style(text, at: 13)?.paragraphSpacingBefore == 0 && (style(text, at: 13)?.paragraphSpacing ?? 0) > 0)
    }

    @Test("A menu item runs only its own enabled command")
    func menuActions() {
        var ran: [String] = []
        NativeMessageMenuAction(MessageMenuCommand(id: "pin", title: "Pin") { ran.append("second") }).invoke(nil)
        NativeMessageMenuAction(MessageMenuCommand(id: "pin", title: "Pin") { ran.append("first") }).invoke(nil)
        NativeMessageMenuAction(
            MessageMenuCommand(id: "delete", title: "Delete", isEnabled: false) { ran.append("disabled") }
        ).invoke(nil)
        NativeMessageMenuAction(MessageMenuCommand(id: "separator", isSeparator: true) { ran.append("separator") })
            .invoke(nil)
        #expect(ran == ["second", "first"])
    }
}
