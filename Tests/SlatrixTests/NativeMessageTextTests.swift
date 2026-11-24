import AppKit
import SwiftUI
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

    // capability: message.rich-text
    @Test("Bold and italic runs get bold and italic fonts")
    func emphasis() {
        #expect(traits(at: 0)?.contains(.bold) == true)
        #expect(traits(at: 4)?.contains(.italic) == true)
    }

    @Test("Code is monospaced and keeps nested bold")
    func code() {
        #expect(traits(at: 10)?.contains(.monoSpace) == true)
        #expect(traits(at: 10)?.contains(.bold) == true)
    }

    @Test("Strikethrough and underline are both applied")
    func strikeAndUnderline() {
        #expect(text.attribute(.strikethroughStyle, at: 14, effectiveRange: nil) as? Int == 1)
        #expect(text.attribute(.underlineStyle, at: 14, effectiveRange: nil) as? Int == 1)
    }

    @Test("A safe link is clickable in the link color without an underline, and a file link is not")
    func links() {
        #expect(text.attribute(.link, at: 20, effectiveRange: nil) as? URL == link)
        #expect(text.attribute(.foregroundColor, at: 20, effectiveRange: nil) as? NSColor == .systemBlue)
        #expect(text.attribute(.underlineStyle, at: 20, effectiveRange: nil) == nil)
        #expect(text.attribute(.link, at: 24, effectiveRange: nil) == nil)
    }

    @Test("A link is underlined only while the pointer is over it")
    func linkHover() throws {
        let view = MessageTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        view.textStorage?.setAttributedString(
            NativeSelectableMessageText.attributed(
                [MessageBodyRun(text: "Read "), MessageBodyRun(text: "the notes", link: link)], fontSize: 15,
                textColor: .labelColor, linkColor: .systemBlue))
        let window = offscreenWindow(NSSize(width: 400, height: 40))
        defer { window.close() }
        window.contentView = view
        let layout = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        layout.ensureLayout(for: container)
        func move(toCharacter index: Int) throws {
            let glyph = layout.glyphIndexForCharacter(at: index)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let point = view.convert(
                NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y), to: nil)
            view.mouseMoved(
                with: try #require(
                    NSEvent.mouseEvent(
                        with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        }
        func underlined(_ index: Int) -> Bool {
            layout.temporaryAttribute(.underlineStyle, atCharacterIndex: index, effectiveRange: nil) != nil
        }
        try move(toCharacter: 7)
        #expect(underlined(7) && underlined(5) && !underlined(2))
        try move(toCharacter: 1)
        #expect(!underlined(7))
    }

    @Test("Text measurement cache survives unchanged updates and clears when lineLimit or text changes")
    func sizeCacheSurvivesUnchangedUpdates() async throws {
        struct Host: View {
            var runs: [MessageBodyRun]
            var lineLimit: Int?
            var tick: Int
            var body: some View {
                NativeSelectableMessageText(
                    runs: runs, fontSize: 14, textColor: .labelColor, linkColor: .systemBlue,
                    menuCommands: { [] }, onOpenURL: { _ in }
                )
                .lineLimit(lineLimit)
                .accessibilityIdentifier("\(tick)")
            }
        }
        let longRuns = [MessageBodyRun(text: String(repeating: "Wrapping message text across lines. ", count: 12))]
        let window = offscreenWindow(NSSize(width: 320, height: 300))
        defer {
            window.contentView = nil
            window.close()
        }
        let hosting = NSHostingView(rootView: Host(runs: longRuns, lineLimit: nil, tick: 0))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func findTextView(_ view: NSView) -> MessageTextView? {
            if let text = view as? MessageTextView { return text }
            for child in view.subviews { if let found = findTextView(child) { return found } }
            return nil
        }
        let textView = try #require(findTextView(hosting))
        let coordinator = try #require(textView.delegate as? NativeSelectableMessageText.Coordinator)
        let sentinel = CGSize(width: 999, height: 999)
        coordinator.sizes[999] = sentinel

        // An unrelated parent redraw keeps the cached layout sizes intact.
        hosting.rootView = Host(runs: longRuns, lineLimit: nil, tick: 1)
        hosting.layoutSubtreeIfNeeded()
        #expect(coordinator.sizes[999] == sentinel)

        // Changing lineLimit invalidates cached sizes and shrinks the laid-out height.
        let unlimitedHeight = hosting.fittingSize.height
        hosting.rootView = Host(runs: longRuns, lineLimit: 1, tick: 2)
        hosting.layoutSubtreeIfNeeded()
        #expect(coordinator.sizes[999] == nil)
        #expect(hosting.fittingSize.height < unlimitedHeight)
    }

    // capability: message.mention-pills
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

    @Test("Headings step down in size from h1 to h3, all above the body, and h4 to h6 share h3's size")
    func headings() throws {
        let runs = MessageBodyRenderer().render(
            body: "", formattedBody: "<h1>A</h1><h2>B</h2><h3>C</h3><h4>D</h4><h6>E</h6><p>f</p>"
        ).runs
        let text = NativeSelectableMessageText.attributed(
            runs, fontSize: 14, textColor: .labelColor, linkColor: .systemBlue)
        let sizes = try ["A", "B", "C", "D", "E", "f"].map { letter in
            let font =
                text.attribute(
                    .font, at: (text.string as NSString).range(of: letter).location, effectiveRange: nil) as? NSFont
            return try #require(font).pointSize
        }
        #expect(sizes[0] > sizes[1] && sizes[1] > sizes[2] && sizes[2] > sizes[5])
        #expect(sizes[3] == sizes[2] && sizes[4] == sizes[2])
    }

    @Test("A blank line between paragraphs is a small gap, not a whole line; in a code block it stays a line")
    func paragraphGap() {
        func gap(_ block: MessageBlock = MessageBlock()) -> CGFloat {
            func secondLine(_ body: String) -> CGFloat {
                let text = NativeSelectableMessageText.attributed(
                    [MessageBodyRun(text: body, block: block)], fontSize: 14, textColor: .labelColor,
                    linkColor: .systemBlue)
                return positions(text, width: 400)(body.count - 1).y
            }
            return secondLine("One\n\nTwo") - secondLine("One\nTwo")
        }
        #expect((6...10).contains(gap()))
        #expect(gap(MessageBlock(code: true)) > 14)
    }

    @Test("Normal paragraphs use paragraph spacing and pushOut line breaking; code blocks keep tight default breaks")
    func paragraphRhythmAndLineBreakStrategy() throws {
        let text = NativeSelectableMessageText.attributed(
            [
                MessageBodyRun(text: "First paragraph\nSecond paragraph\n"),
                MessageBodyRun(text: "let a = 1\nlet b = 2\n", style: .code, block: MessageBlock(code: true)),
                MessageBodyRun(text: "Trailing prose"),
            ], fontSize: 14, textColor: .labelColor, linkColor: .systemBlue)
        let normal = try #require(style(text, at: 0))
        #expect(normal.paragraphSpacing > 2 && normal.paragraphSpacing <= 5)
        #expect(normal.lineBreakStrategy == .pushOut)

        let codeStart = (text.string as NSString).range(of: "let a = 1").location
        let codeFirst = try #require(style(text, at: codeStart))
        #expect(codeFirst.paragraphSpacing == 0)
        #expect(codeFirst.lineBreakStrategy == [])
    }

    @Test("A single-line quote draws its bar across the full line height down past the baseline")
    func singleLineQuoteBarCoversFullLineHeight() throws {
        let storage = laidOut([MessageBodyRun(text: "Quoted line", block: MessageBlock(quote: 1))], width: 300)
        let layout = try #require(storage.layoutManagers.first as? PillLayoutManager)
        let size = NSSize(width: 300, height: 40)
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        layout.drawBlocks(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs), at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        let barColumn = Int(MessageBlocks.barWidth(15) / 2)
        let paintedY = (0..<Int(size.height)).filter { y in
            (rep.colorAt(x: barColumn, y: y)?.alphaComponent ?? 0) > 0.05
        }
        let barHeight = (paintedY.last ?? 0) - (paintedY.first ?? 0) + 1
        let font = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(
            CGFloat(barHeight) >= font.ascender,
            "Quote bar height (\(barHeight) px) ended above the baseline (ascender \(font.ascender))")
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
        #expect(at(0).x < at(2).x)
        #expect(abs(at(wrapped).x - at(2).x) < 0.5)
    }

    @Test("A bullet and a number end the same distance before their item's text, which starts at one indent")
    func listMarkers() {
        let list = MessageBlock(list: 1)
        let storage = laidOut([
            MessageBodyRun(text: "• ", block: list, marker: true), MessageBodyRun(text: "one\n", block: list),
            MessageBodyRun(text: "12. ", block: list, marker: true), MessageBodyRun(text: "two", block: list),
        ])
        func at(_ index: Int) -> NSRect { glyphs(storage, NSRange(location: index, length: 1)) }
        let bulletGap = at(2).minX - at(0).maxX
        let numberGap = at(10).minX - at(8).maxX
        #expect(abs(bulletGap - numberGap) < 0.5)
        #expect(at(2).minX == at(10).minX)
    }

    @Test(
        "A number wider than its list's indent pushes the item's text over, wrapped lines too, clear of the quote's bar"
    )
    func wideMarkerInQuote() {
        let item = "one two three four five six seven eight nine ten eleven twelve"
        let runs = MessageBodyRenderer().render(
            body: "", formattedBody: "<blockquote><ol start=\"1000000\"><li>\(item)</li></ol></blockquote>"
        ).runs
        let storage = laidOut(runs, width: 200)
        let text = storage.string as NSString
        let marker = glyphs(storage, text.range(of: "1000000."))
        let first = glyphs(storage, text.range(of: "one"))
        #expect(marker.minX >= MessageBlocks.quoteIndent(15) && first.minX > marker.maxX)
        let layout = storage.layoutManagers[0]
        var line = NSRange()
        layout.lineFragmentRect(forGlyphAt: layout.numberOfGlyphs - 1, effectiveRange: &line)
        let wrapped = glyphs(storage, NSRange(location: layout.characterIndexForGlyph(at: line.location), length: 1))
        #expect(wrapped.minY > first.minY && abs(wrapped.minX - first.minX) < 0.5)
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

    /// `runs` laid out in a message's text system; the storage owns the layout manager.
    private func laidOut(_ runs: [MessageBodyRun], width: CGFloat = 400) -> NSTextStorage {
        let pills = MentionPalette(
            me: nil, text: .systemBlue, fill: .systemTeal, ownText: .systemBrown, ownFill: .systemYellow)
        let storage = NSTextStorage(
            attributedString: NativeSelectableMessageText.attributed(
                runs, fontSize: 15, textColor: .labelColor, linkColor: .systemBlue, mentions: pills))
        let layout = PillLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return storage
    }
    private func mention(_ name: String) -> MessageBodyRun {
        MessageBodyRun(text: "@" + name, mention: "@\(name.lowercased()):example.org")
    }
    private func pills(_ storage: NSTextStorage) -> [NSRect] {
        let layout = storage.layoutManagers[0] as! PillLayoutManager
        return layout.pills(forCharacterRange: NSRange(location: 0, length: storage.length)).map(\.rect)
    }
    /// Where the characters in `range` sit on their line, in text container coordinates, as a selection encloses them.
    private func glyphs(_ storage: NSTextStorage, _ range: NSRange) -> NSRect {
        let layout = storage.layoutManagers[0]
        var box = NSRect.null
        layout.enumerateEnclosingRects(
            forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: layout.textContainers[0]
        ) { rect, _ in box = box.union(rect) }
        return box
    }

    @Test("A mention's pill is as tall beside an emoji or a taller script, or above another line, as on a plain line")
    func pillHeight() throws {
        let plain = try #require(pills(laidOut([MessageBodyRun(text: "Thanks "), mention("Alice")])).first)
        let tall = try #require(pills(laidOut([MessageBodyRun(text: "Thanks 🎉 สวัสดี "), mention("Alice")])).first)
        let above = try #require(pills(laidOut([mention("Alice"), MessageBodyRun(text: "\nThanks")])).first)
        #expect(abs(tall.height - plain.height) < 0.5)
        #expect(abs(above.height - plain.height) < 0.5)
    }

    @Test("A mention that fits on a line moves to the next one whole instead of breaking inside the name")
    func mentionKeepsTogether() throws {
        let name = mention("Евгения Красносельская-Тихомирова")
        let alone = laidOut([name], width: 2_000)
        let width = glyphs(alone, NSRange(location: 0, length: alone.length)).width + 20
        let storage = laidOut([MessageBodyRun(text: "Reviewers this week: "), name], width: width)
        let mentionRange = NSRange(location: 21, length: storage.length - 21)
        #expect(pills(storage).count == 1)
        #expect(glyphs(storage, mentionRange).minX < 1)
    }

    /// `storage`'s glyphs as drawn into a bitmap `size` points large, one pixel a point.
    private func drawn(_ storage: NSTextStorage, _ size: NSSize) throws -> NSBitmapImageRep {
        let layout = try #require(storage.layoutManagers.first)
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        layout.drawGlyphs(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs), at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    private func inked(_ rep: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> [Int] {
        x.filter { x in y.contains { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 } }
    }

    @Test("A fill only paints: no character moves for it, even where many code spans border one accented letter")
    func pillsAddNoKern() {
        let runs = MessageBodyRenderer().render(
            body: "", formattedBody: "a<code>\u{0301}</code>\u{0301}<code>\u{0301}</code> b"
        ).runs
        let text = NativeSelectableMessageText.attributed(
            runs, fontSize: 15, textColor: .labelColor, linkColor: .systemBlue,
            mentions: MentionPalette(
                me: nil, text: .systemBlue, fill: .systemTeal, ownText: .systemBrown, ownFill: .systemYellow))
        var kerned = false
        text.enumerateAttribute(.kern, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            kerned = kerned || value != nil
        }
        #expect(!kerned)
    }

    @Test("Inline code too long for a line wraps with its fill and letters inside the column")
    func inlineCodeWraps() throws {
        let code = MessageBodyRun(text: String(repeating: "M", count: 60), style: .code)
        let font = try #require(laidOut([code]).attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let width = 24 * NSAttributedString(string: "M", attributes: [.font: font]).size().width + 1
        let storage = laidOut([code], width: width)
        let found = pills(storage)
        #expect(found.count > 1 && found.allSatisfy { $0.minX >= 0 && $0.maxX <= width + 0.01 })
        let rep = try drawn(storage, NSSize(width: width + 40, height: 160))
        #expect(inked(rep, x: Int(width.rounded(.up))..<Int(width) + 40, y: 0..<160).isEmpty)
    }

    @Test("Inline code in right-to-left text sits on a fill around its letters, clear of the words beside it")
    func inlineCodeRightToLeft() throws {
        let runs = MessageBodyRenderer().render(body: "", formattedBody: "<p>לפני <code>אבג</code> אחרי</p>").runs
        let storage = laidOut(runs)
        let fill = try #require(pills(storage).first)
        let text = storage.string as NSString
        let code = glyphs(storage, text.range(of: "אבג"))
        #expect(fill.minX <= code.minX + 0.01 && fill.maxX >= code.maxX - 0.01)
        for neighbor in [text.range(of: "לפני"), text.range(of: "אחרי")] {
            #expect(!glyphs(storage, neighbor).intersects(fill))
        }
    }

    @Test("A message of only emoji shows them larger than text, but a preview keeps them at text size")
    func emojiSize() throws {
        func size(_ body: String, large: Bool = true) throws -> CGFloat {
            let hosting = NSHostingView(
                rootView: NativeMessageBody(body: body, formattedBody: nil, largeEmoji: large)
                    .environmentObject(AppearanceStore()))
            hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            hosting.layoutSubtreeIfNeeded()
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let text = try #require(views(hosting).compactMap { $0 as? MessageTextView }.first)
            let font = text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            return try #require(font).pointSize
        }
        let reading = Metrics().size(.reading)
        #expect(try size("🎉") > reading)
        #expect(try size("Nice 🎉") == reading)
        #expect(try size("🎉", large: false) == reading)
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
