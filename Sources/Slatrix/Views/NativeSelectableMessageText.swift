import AppKit
import SwiftUI

/// How mention pills look to this reader: a mention of `me`, or of the room, is the yellow one.
struct MentionPalette: Equatable {
    var me: String?
    var text: NSColor
    var fill: NSColor
    var ownText: NSColor
    var ownFill: NSColor
}

extension NSAttributedString.Key {
    /// A mention pill's fill, which `PillLayoutManager` draws rounded behind the text.
    static let mentionPill = NSAttributedString.Key("SlatrixMentionPill")
    /// Inline code's fill, which `PillLayoutManager` draws as it draws a mention's.
    static let codeSpan = NSAttributedString.Key("SlatrixCodeSpan")
}

/// Draws `.mentionPill` and `.codeSpan` runs as Slack's inline mentions and code: a rounded fill as tall as the font,
/// whatever the line holds, around the letters and a little past them. It is only paint: no text moves for it. A
/// mention that fits on the next line wraps there whole.
class PillLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    static let keys: [NSAttributedString.Key] = [.mentionPill, .codeSpan]

    override init() {
        super.init()
        delegate = self
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool
    {
        guard let storage = textStorage, charIndex > 0, charIndex < storage.length else { return true }
        var mention = NSRange()
        return storage.attribute(.mentionPill, at: charIndex, effectiveRange: &mention) == nil
            || mention.location == charIndex
    }

    struct Pill {
        /// In text container coordinates, one per line the mention spans.
        var rect: NSRect
        var radius: CGFloat
        var fill: NSColor
    }

    /// How far a fill reaches past its letters on each side, in proportion to the font so pills scale with zoom.
    static func padding(_ font: NSFont) -> CGFloat { font.pointSize * 0.13 }

    func pills(forCharacterRange characters: NSRange) -> [Pill] {
        guard let storage = textStorage else { return [] }
        var pills: [Pill] = []
        for key in Self.keys {
            storage.enumerateAttribute(key, in: characters) { value, range, _ in
                guard let fill = value as? NSColor,
                    let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                else { return }
                // The small radius at the reading size, scaled with the font, and a hair more than the font's height.
                let radius = font.pointSize * Metrics().radiusSmall / TextRole.reading.points
                let bleed = font.pointSize * 0.05
                let padding = Self.padding(font)
                let text = storage.string as NSString
                var glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                // One fill per line the pill spans, around its letters there as a selection encloses them, in either
                // direction, and kept on that line so a wrapped pill never paints past the column.
                while glyphs.length > 0 {
                    var line = NSRange()
                    let fragment = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: &line)
                    guard let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { break }
                    let part = NSIntersectionRange(glyphs, line)
                    glyphs = NSRange(location: NSMaxRange(part), length: NSMaxRange(glyphs) - NSMaxRange(part))
                    // A pill that wraps ends the line at its last word.
                    var words = characterRange(forGlyphRange: part, actualGlyphRange: nil)
                    while words.length > 1, text.character(at: NSMaxRange(words) - 1) == 0x20 { words.length -= 1 }
                    var box = NSRect.null
                    enumerateEnclosingRects(
                        forGlyphRange: glyphRange(forCharacterRange: words, actualCharacterRange: nil),
                        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
                    ) { rect, _ in box = box.union(rect) }
                    guard !box.isNull else { continue }
                    let minX = max(fragment.minX, box.minX - padding)
                    let maxX = min(fragment.maxX, box.maxX + padding)
                    // From the baseline, so taller glyphs elsewhere on the line or line spacing never stretch it.
                    let baseline = fragment.minY + location(forGlyphAt: part.location).y
                    let rect = NSRect(
                        x: minX, y: baseline - font.ascender - bleed, width: maxX - minX,
                        height: font.ascender - font.descender + 2 * bleed)
                    pills.append(Pill(rect: rect, radius: radius, fill: fill))
                }
            }
        }
        return pills
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawBlocks(forGlyphRange: glyphsToShow, at: origin)
        for pill in pills(forCharacterRange: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)) {
            pill.fill.setFill()
            NSBezierPath(
                roundedRect: pill.rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: pill.radius,
                yRadius: pill.radius
            ).fill()
        }
        // After the pills, so a selection highlight covers them.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// Compact mode's sender name flowing at the start of a plain or inline message.
struct InlineSenderPrefix: Equatable {
    var name: String
    var color: NSColor
}

struct NativeSelectableMessageText: NSViewRepresentable {
    /// Layout width until SwiftUI proposes one; never seen on screen.
    private static let fallbackWidth: CGFloat = 480
    fileprivate static let senderURL = URL(string: "slatrix-sender://profile")!
    var runs: [MessageBodyRun]
    var fontSize: Double
    var textColor: NSColor
    var linkColor: NSColor
    var mentions: MentionPalette? = nil
    /// Compact mode's sender name flowing before the first word.
    var senderPrefix: InlineSenderPrefix? = nil
    var onOpenSender: (() -> Void)? = nil
    /// Muted text after the last word, such as "(edited)".
    var suffix: NSAttributedString? = nil
    var menuCommands: () -> [MessageMenuCommand]
    var onOpenURL: (URL) -> Void
    @Environment(\.lineLimit) private var lineLimit

    func makeNSView(context: Context) -> MessageTextView {
        let container = NSTextContainer(
            size: NSSize(width: Self.fallbackWidth, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        let layout = PillLayoutManager()
        layout.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        let view = MessageTextView(frame: .zero, textContainer: container)
        view.drawsBackground = false
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.importsGraphics = false
        view.allowsImageEditing = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.textContainerInset = .zero
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Message")
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: MessageTextView, context: Context) {
        let maxLines = max(0, lineLimit ?? 0)
        let limitChanged = context.coordinator.maximumNumberOfLines != maxLines
        let textChanged =
            context.coordinator.runs != runs || context.coordinator.fontSize != fontSize
            || context.coordinator.textColor != textColor || context.coordinator.linkColor != linkColor
            || context.coordinator.mentions != mentions || context.coordinator.senderPrefix != senderPrefix
            || context.coordinator.senderLinkable != (onOpenSender != nil) || context.coordinator.suffix != suffix
        if textChanged || limitChanged { context.coordinator.sizes = [:] }
        context.coordinator.onOpenURL = onOpenURL
        context.coordinator.onOpenSender = onOpenSender
        view.menuCommands = menuCommands
        view.isCovered = context.environment.isCovered
        if limitChanged {
            view.textContainer?.maximumNumberOfLines = maxLines
            view.textContainer?.lineBreakMode = lineLimit == nil ? .byWordWrapping : .byTruncatingTail
            context.coordinator.maximumNumberOfLines = maxLines
        }
        // Each run styles its own link, so a mention pill isn't underlined until the pointer is over it.
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        if textChanged {
            let attributed = NSMutableAttributedString(
                attributedString: Self.attributed(
                    runs, fontSize: fontSize, textColor: textColor, linkColor: linkColor, mentions: mentions))
            var prefixLength = 0
            if let senderPrefix {
                let style =
                    (attributed.length > 0
                        ? attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil)
                    ?? MessageBlocks.paragraph(
                        quote: false, list: 0, code: false, marker: 0, heading: false, fontSize: fontSize,
                        lineSpacing: MessageBlocks.readingLineSpacing(fontSize))
                var nameAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: senderPrefix.color,
                    .paragraphStyle: style,
                ]
                if onOpenSender != nil { nameAttributes[.link] = Self.senderURL }
                let prefix = NSMutableAttributedString(string: senderPrefix.name, attributes: nameAttributes)
                prefix.append(
                    NSAttributedString(
                        string: "  ",
                        attributes: [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: style]))
                prefixLength = prefix.length
                attributed.insert(prefix, at: 0)
            }
            if let suffix { attributed.append(suffix) }
            let oldText = view.string as NSString
            let oldPrefix = min(view.senderPrefixLength, oldText.length)
            let newText = attributed.string as NSString
            let sameBody = oldText.substring(from: oldPrefix) == newText.substring(from: prefixLength)
            let delta = prefixLength - oldPrefix
            let selection: [NSValue] =
                if sameBody {
                    view.selectedRanges.map { value in
                        let range = value.rangeValue
                        if range.length == 0 { return NSValue(range: NSRange(location: 0, length: 0)) }
                        let start = min(max(0, range.location + delta), newText.length)
                        let length = min(range.length, newText.length - start)
                        return NSValue(range: NSRange(location: start, length: length))
                    }
                } else {
                    [NSValue(range: NSRange(location: 0, length: 0))]
                }
            view.senderPrefixLength = prefixLength
            view.textStorage?.setAttributedString(attributed)
            view.selectedRanges = selection
            context.coordinator.runs = runs
            context.coordinator.fontSize = fontSize
            context.coordinator.textColor = textColor
            context.coordinator.linkColor = linkColor
            context.coordinator.mentions = mentions
            context.coordinator.senderPrefix = senderPrefix
            context.coordinator.senderLinkable = onOpenSender != nil
            context.coordinator.suffix = suffix
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? Self.fallbackWidth)
        let line = ceil(fontSize + 3)
        // Stacks probe with a zero width; laying text out a glyph per line would be the costliest layout of all.
        guard width >= fontSize * 2 else { return CGSize(width: width, height: line) }
        if let size = context.coordinator.sizes[width] { return size }
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else {
            return CGSize(width: width, height: fontSize + 4)
        }
        if abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let size = CGSize(width: width, height: max(line, ceil(layout.usedRect(for: container).height)))
        context.coordinator.sizes[width] = size
        return size
    }

    func makeCoordinator() -> Coordinator { Coordinator(onOpenURL: onOpenURL) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var runs: [MessageBodyRun]?
        var fontSize: Double?
        var textColor: NSColor?
        var linkColor: NSColor?
        var mentions: MentionPalette?
        var senderPrefix: InlineSenderPrefix?
        var senderLinkable = false
        var maximumNumberOfLines: Int?
        var suffix: NSAttributedString?
        /// Laid-out sizes by width for the current text; a timeline row is measured at one or two widths, many times.
        var sizes: [CGFloat: CGSize] = [:]
        var onOpenURL: (URL) -> Void
        var onOpenSender: (() -> Void)?
        init(onOpenURL: @escaping (URL) -> Void) { self.onOpenURL = onOpenURL }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let source = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
            if source == NativeSelectableMessageText.senderURL.absoluteString {
                onOpenSender?()
                return true
            }
            if let url = MessageBodyRenderer.safeLink(source) { onOpenURL(url) }
            return true
        }
    }

    static func attributed(
        _ runs: [MessageBodyRun], fontSize: Double, textColor: NSColor, linkColor: NSColor,
        mentions: MentionPalette? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lineSpacing = MessageBlocks.readingLineSpacing(fontSize)
        var paragraph = NSParagraphStyle()
        var lineStart = true
        for run in runs {
            let base = run.block.heading > 0 ? MessageBlocks.headingSize(run.block.heading, fontSize) : fontSize
            let size = run.style.contains(.code) ? max(10, base - 1) : base
            var font =
                run.style.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
            var traits = font.fontDescriptor.symbolicTraits
            if run.style.contains(.bold) { traits.insert(.bold) }
            if run.style.contains(.italic) { traits.insert(.italic) }
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size) ?? font
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            if run.style.contains(.strike) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if run.style.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.block.code {
                attributes[.codeBlock] = textColor.withAlphaComponent(0.04)
            } else if run.style.contains(.code) {
                attributes[.codeSpan] = textColor.withAlphaComponent(0.07)
            }
            if run.block.quote > 0 { attributes[.quoteBar] = textColor.withAlphaComponent(0.25) }
            if let link = run.link.flatMap({ MessageBodyRenderer.safeLink($0.absoluteString) }) {
                attributes[.link] = link
                attributes[.foregroundColor] = linkColor
            }
            if let mention = run.mention, let mentions {
                let own = mention == mentions.me || mention == "@room"
                attributes[.foregroundColor] = own ? mentions.ownText : mentions.text
                attributes[.underlineStyle] = nil
                attributes[.mentionPill] = own ? mentions.ownFill : mentions.fill
            }
            let style = { (marker: CGFloat) in
                MessageBlocks.paragraph(
                    quote: run.block.quote > 0, list: run.block.list, code: run.block.code, marker: marker,
                    heading: run.block.heading > 0 && result.length > 0, fontSize: fontSize, lineSpacing: lineSpacing)
            }
            if run.marker {
                // The marker and its space end at the list indent, so bullets and numbers sit the same distance from
                // their text, and a wrapped line starts under the item's first word.
                let marker = MessageBlocks.marker(run.text, attributes: attributes)
                paragraph = style(marker.size().width)
                marker.addAttribute(
                    .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: marker.length))
                result.append(marker)
                lineStart = false
                continue
            }
            if lineStart { paragraph = style(0) }
            attributes[.paragraphStyle] = paragraph
            // The run's later lines are lines of their own, which never start with a marker.
            let text = run.text as NSString
            let firstBreak = text.range(of: "\n")
            let head = firstBreak.location == NSNotFound ? text.length : NSMaxRange(firstBreak)
            result.append(NSAttributedString(string: text.substring(to: head), attributes: attributes))
            if head < text.length {
                paragraph = style(0)
                attributes[.paragraphStyle] = paragraph
                result.append(NSAttributedString(string: text.substring(from: head), attributes: attributes))
            }
            lineStart = run.text.hasSuffix("\n")
        }
        MessageBlocks.padCodeBlocks(result, in: NSRange(location: 0, length: result.length), fontSize: fontSize)
        MessageBlocks.shrinkBlankLines(result, fontSize: fontSize)
        return result
    }
}

final class MessageTextView: NSTextView {
    var menuCommands: () -> [MessageMenuCommand] = { [] }
    /// UTF-16 length of the compact inline sender prefix ("Name  "), excluded when copying body text.
    var senderPrefixLength = 0

    func copyableText(for range: NSRange) -> String {
        let text = string as NSString
        let prefix = min(senderPrefixLength, text.length)
        if range.length == 0 { return text.substring(from: prefix) }
        let end = min(NSMaxRange(range), text.length)
        guard range.location < end else { return "" }
        let start = (prefix > 0 && range.location < prefix && end > prefix) ? prefix : range.location
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    override func copy(_ sender: Any?) {
        guard senderPrefixLength > 0 else { return super.copy(sender) }
        let range = selectedRange()
        guard range.location != NSNotFound, range.length > 0 else { return super.copy(sender) }
        let copied = copyableText(for: range)
        guard !copied.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copied, forType: .string)
    }

    /// A message never scrolls the timeline: AppKit asks a resized text view to reveal its selection, which would
    /// pull a resizing conversation away from its newest message.
    override func scrollToVisible(_ rect: NSRect) -> Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // AppKit hands the text view the pointer across its whole visible rect, including where SwiftUI draws a control
    // on top of it (the hover toolbar, a toast, or an in-window modal), so the I-beam applies only when uncovered and
    // under the pointer.
    var isCovered = false {
        didSet {
            guard isCovered != oldValue else { return }
            syncCoveredCursor()
        }
    }
    var effectivelyCovered: Bool {
        isCovered || (enclosingScrollView as? TimelineScrollView)?.isCovered == true
    }
    func syncCoveredCursor() {
        if effectivelyCovered {
            pointerOverText = false
            underlineMention(at: nil)
            if NSCursor.current == .iBeam { NSCursor.arrow.set() }
        }
        window?.invalidateCursorRects(for: self)
    }
    private var pointerOverText: Bool?
    override func resetCursorRects() {
        guard !effectivelyCovered else { return }
        super.resetCursorRects()
    }
    override func cursorUpdate(with event: NSEvent) {
        guard !effectivelyCovered else {
            pointerOverText = false
            return
        }
        pointerOverText = isUnderPointer(event)
        if pointerOverText == true { super.cursorUpdate(with: event) } else { NSCursor.arrow.set() }
    }
    override func mouseMoved(with event: NSEvent) {
        guard !effectivelyCovered else {
            pointerOverText = false
            underlineMention(at: nil)
            return
        }
        super.mouseMoved(with: event)
        underlineMention(at: event)
        let over = isUnderPointer(event)
        guard over != pointerOverText else { return }
        pointerOverText = over
        (over ? NSCursor.iBeam : NSCursor.arrow).set()
    }

    // Slack underlines the mention or link under the pointer, and only that one.
    private var underlinedMention: NSRange?
    private lazy var exitTracking = NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(exitTracking) { addTrackingArea(exitTracking) }
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        underlineMention(at: nil)
    }
    private func underlineMention(at event: NSEvent?) {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return }
        var mention: NSRange?
        if let event {
            let point = convert(event.locationInWindow, from: nil)
            let glyph = layout.glyphIndex(for: point, in: container)
            var range = NSRange()
            if glyph < layout.numberOfGlyphs,
                layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point)
            {
                let index = layout.characterIndexForGlyph(at: glyph)
                let all = NSRange(location: 0, length: storage.length)
                if storage.attribute(.mentionPill, at: index, longestEffectiveRange: &range, in: all) != nil
                    || storage.attribute(.link, at: index, longestEffectiveRange: &range, in: all) != nil
                {
                    mention = range
                }
            }
        }
        guard mention != underlinedMention else { return }
        if let old = underlinedMention {
            let valid = NSIntersectionRange(old, NSRange(location: 0, length: storage.length))
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: valid)
        }
        if let mention {
            layout.addTemporaryAttribute(
                .underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: mention)
        }
        underlinedMention = mention
    }

    private func isUnderPointer(_ event: NSEvent) -> Bool {
        guard let content = window?.contentView else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        return content.hitTest(point)?.isDescendant(of: self) == true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        var commands = menuCommands()
        let proposedRange = selectedRange()
        let range =
            proposedRange.location != NSNotFound && NSMaxRange(proposedRange) <= (string as NSString).length
            ? proposedRange : NSRange(location: 0, length: 0)
        if range.length > 0 || commands.isEmpty {
            let selection = copyableText(for: range)
            let copy = MessageMenuCommand(
                id: "native-copy-selection", title: range.length > 0 ? "Copy selection" : "Copy text",
                isEnabled: !selection.isEmpty
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selection, forType: .string)
            }
            if !commands.isEmpty {
                commands.insert(MessageMenuCommand(id: "native-copy-separator", isSeparator: true), at: 0)
            }
            commands.insert(copy, at: 0)
        }
        return NativeMessageMenu.make(commands: commands)
    }
}
