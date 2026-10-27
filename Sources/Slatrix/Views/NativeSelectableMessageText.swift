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
}

/// Draws `.mentionPill` fills as rounded pills, a little wider than their text and as tall as the line.
class PillLayoutManager: NSLayoutManager {
    struct Pill {
        /// In text container coordinates, one per line the mention spans.
        var rect: NSRect
        var radius: CGFloat
        var fill: NSColor
    }

    func pills(forCharacterRange characters: NSRange) -> [Pill] {
        guard let storage = textStorage, let container = textContainers.first else { return [] }
        var pills: [Pill] = []
        storage.enumerateAttribute(.mentionPill, in: characters) { value, range, _ in
            guard let fill = value as? NSColor,
                let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            else { return }
            let spacing =
                (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                .lineSpacing ?? 0
            // In proportion to the font, so pills scale with zoom: 2 pt of padding and a 3 pt radius at 15 pt.
            let padding = font.pointSize * 0.13
            let radius = font.pointSize * 0.2
            enumerateEnclosingRects(
                forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                let pill = NSRect(
                    x: rect.minX - padding, y: rect.minY, width: rect.width + 2 * padding,
                    height: rect.height - spacing)
                pills.append(Pill(rect: pill, radius: radius, fill: fill))
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

struct NativeSelectableMessageText: NSViewRepresentable {
    /// Layout width until SwiftUI proposes one; never seen on screen.
    private static let fallbackWidth: CGFloat = 480
    var runs: [MessageBodyRun]
    var fontSize: Double
    var textColor: NSColor
    var linkColor: NSColor
    var mentions: MentionPalette? = nil
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
        context.coordinator.sizes = [:]
        context.coordinator.onOpenURL = onOpenURL
        view.menuCommands = menuCommands
        view.textContainer?.maximumNumberOfLines = max(0, lineLimit ?? 0)
        view.textContainer?.lineBreakMode = lineLimit == nil ? .byWordWrapping : .byTruncatingTail
        // Each run styles its own link, so a mention pill isn't underlined until the pointer is over it.
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        if context.coordinator.runs != runs || context.coordinator.fontSize != fontSize
            || context.coordinator.textColor != textColor || context.coordinator.linkColor != linkColor
            || context.coordinator.mentions != mentions || context.coordinator.suffix != suffix
        {
            let attributed = NSMutableAttributedString(
                attributedString: Self.attributed(
                    runs, fontSize: fontSize, textColor: textColor, linkColor: linkColor, mentions: mentions))
            if let suffix { attributed.append(suffix) }
            let selection =
                view.string == attributed.string
                ? view.selectedRanges : [NSValue(range: NSRange(location: 0, length: 0))]
            view.textStorage?.setAttributedString(attributed)
            view.selectedRanges = selection
            context.coordinator.runs = runs
            context.coordinator.fontSize = fontSize
            context.coordinator.textColor = textColor
            context.coordinator.linkColor = linkColor
            context.coordinator.mentions = mentions
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
        var suffix: NSAttributedString?
        /// Laid-out sizes by width for the current text; a timeline row is measured at one or two widths, many times.
        var sizes: [CGFloat: CGSize] = [:]
        var onOpenURL: (URL) -> Void
        init(onOpenURL: @escaping (URL) -> Void) { self.onOpenURL = onOpenURL }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let source = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
            if let url = MessageBodyRenderer.safeLink(source) { onOpenURL(url) }
            return true
        }
    }

    static func attributed(
        _ runs: [MessageBodyRun], fontSize: Double, textColor: NSColor, linkColor: NSColor,
        mentions: MentionPalette? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lineSpacing = fontSize / 5  // 3 pt at the 15 pt body, scaling with zoom.
        var paragraph = NSParagraphStyle()
        var lineStart = true
        for run in runs {
            let size = run.style.contains(.code) ? max(10, fontSize - 1) : fontSize
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
                attributes[.backgroundColor] = textColor.withAlphaComponent(0.07)
            }
            if run.block.quote > 0 { attributes[.quoteBar] = textColor.withAlphaComponent(0.25) }
            if let link = run.link.flatMap({ MessageBodyRenderer.safeLink($0.absoluteString) }) {
                attributes[.link] = link
                attributes[.foregroundColor] = linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if let mention = run.mention, let mentions {
                let own = mention == mentions.me || mention == "@room"
                attributes[.foregroundColor] = own ? mentions.ownText : mentions.text
                attributes[.underlineStyle] = nil
                attributes[.mentionPill] = own ? mentions.ownFill : mentions.fill
            }
            let style = { (marker: Bool) in
                MessageBlocks.paragraph(
                    quote: run.block.quote > 0, list: run.block.list, code: run.block.code, hangingMarker: marker,
                    fontSize: fontSize, lineSpacing: lineSpacing)
            }
            if lineStart { paragraph = style(run.marker) }
            attributes[.paragraphStyle] = paragraph
            if run.marker, let space = run.text.last {
                // The marker fills the list indent, so a wrapped line starts under the item's first word.
                let width = NSAttributedString(string: run.text, attributes: attributes).size().width
                result.append(NSAttributedString(string: String(run.text.dropLast()), attributes: attributes))
                attributes[.kern] = max(0, MessageBlocks.listIndent(fontSize) - width)
                result.append(NSAttributedString(string: String(space), attributes: attributes))
                lineStart = false
                continue
            }
            // The run's later lines are lines of their own, which never start with a marker.
            let text = run.text as NSString
            let firstBreak = text.range(of: "\n")
            let head = firstBreak.location == NSNotFound ? text.length : NSMaxRange(firstBreak)
            result.append(NSAttributedString(string: text.substring(to: head), attributes: attributes))
            if head < text.length {
                paragraph = style(false)
                attributes[.paragraphStyle] = paragraph
                result.append(NSAttributedString(string: text.substring(from: head), attributes: attributes))
            }
            lineStart = run.text.hasSuffix("\n")
        }
        MessageBlocks.padCodeBlocks(result, in: NSRange(location: 0, length: result.length), fontSize: fontSize)
        return result
    }
}

final class MessageTextView: NSTextView {
    var menuCommands: () -> [MessageMenuCommand] = { [] }

    /// A message never scrolls the timeline: AppKit asks a resized text view to reveal its selection, which would
    /// pull a resizing conversation away from its newest message.
    override func scrollToVisible(_ rect: NSRect) -> Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // AppKit hands the text view the pointer across its whole visible rect, including where SwiftUI draws a control
    // on top of it (the hover toolbar, a toast), so the I-beam applies only where the text is the view under it.
    private var pointerOverText: Bool?
    override func cursorUpdate(with event: NSEvent) {
        pointerOverText = isUnderPointer(event)
        if pointerOverText == true { super.cursorUpdate(with: event) } else { NSCursor.arrow.set() }
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        underlineMention(at: event)
        let over = isUnderPointer(event)
        guard over != pointerOverText else { return }
        pointerOverText = over
        (over ? NSCursor.iBeam : NSCursor.arrow).set()
    }

    // Slack underlines the mention under the pointer.
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
                layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point),
                storage.attribute(
                    .mentionPill, at: layout.characterIndexForGlyph(at: glyph), longestEffectiveRange: &range,
                    in: NSRange(location: 0, length: storage.length)) != nil
            {
                mention = range
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
            let selection = range.length > 0 ? (string as NSString).substring(with: range) : string
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
