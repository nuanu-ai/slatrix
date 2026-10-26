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
