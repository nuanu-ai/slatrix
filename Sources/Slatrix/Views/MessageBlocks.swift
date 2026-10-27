import AppKit

extension NSAttributedString.Key {
    /// The bar beside a quote's lines, which `PillLayoutManager` draws.
    static let quoteBar = NSAttributedString.Key("SlatrixQuoteBar")
    /// The fill behind a code block's lines, which `PillLayoutManager` draws.
    static let codeBlock = NSAttributedString.Key("SlatrixCodeBlock")
}

/// Slack's blocks, shared by messages and the composer: a quote indents past a grey bar, a list item's wrapped lines
/// line up past its marker, and a code block sits on a padded, rounded fill. Sizes follow the font, so zoom scales
/// them.
enum MessageBlocks {
    static func listIndent(_ fontSize: CGFloat) -> CGFloat { fontSize * 1.6 }
    static func quoteIndent(_ fontSize: CGFloat) -> CGFloat { fontSize }
    static func barWidth(_ fontSize: CGFloat) -> CGFloat { fontSize * 0.27 }
    static func codePadding(_ fontSize: CGFloat) -> CGFloat { fontSize * 0.5 }

    /// A line's style. `hangingMarker`: the line starts with its list marker as text, inside the indent.
    static func paragraph(
        quote: Bool, list: Int, code: Bool, hangingMarker: Bool = false, fontSize: CGFloat, lineSpacing: CGFloat
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let indent =
            (quote ? quoteIndent(fontSize) : 0) + CGFloat(list) * listIndent(fontSize)
            + (code ? codePadding(fontSize) : 0)
        style.headIndent = indent
        style.firstLineHeadIndent = hangingMarker ? indent - listIndent(fontSize) : indent
        if code { style.tailIndent = -codePadding(fontSize) }
        return style
    }

    /// Pads the first and last lines of each code block in `range`, inside its fill.
    static func padCodeBlocks(_ text: NSMutableAttributedString, in range: NSRange, fontSize: CGFloat) {
        let string = text.string as NSString
        string.enumerateSubstrings(
            in: string.paragraphRange(for: range), options: [.byParagraphs, .substringNotRequired]
        ) { _, _, paragraph, _ in
            guard paragraph.length > 0, text.attribute(.codeBlock, at: paragraph.location, effectiveRange: nil) != nil,
                let style =
                    (text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
                    as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            else { return }
            let end = NSMaxRange(paragraph)
            let first =
                paragraph.location == 0
                || text.attribute(.codeBlock, at: paragraph.location - 1, effectiveRange: nil) == nil
            let last = end >= text.length || text.attribute(.codeBlock, at: end, effectiveRange: nil) == nil
            style.paragraphSpacingBefore = first ? codePadding(fontSize) : 0
            style.paragraphSpacing = last ? codePadding(fontSize) : 0
            text.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
    }

    /// A quote's bar or a code block's fill beside or behind `lines`, the union of the block's line fragments.
    static func draw(
        _ key: NSAttributedString.Key, color: NSColor, lines: NSRect, style: NSParagraphStyle?, fontSize: CGFloat
    ) {
        let height = lines.height - (style?.lineSpacing ?? 0)
        if key == .codeBlock {
            let padding = style.map { -$0.tailIndent } ?? codePadding(fontSize)
            let left = (style?.headIndent ?? padding) - padding
            let path = NSBezierPath(
                roundedRect: NSRect(
                    x: lines.minX + left + 0.5, y: lines.minY + 0.5, width: lines.width - left - 1,
                    height: height - 1),
                xRadius: padding * 0.6, yRadius: padding * 0.6)
            color.setFill()
            path.fill()
            // The border is the fill, stronger.
            color.withAlphaComponent(min(1, color.alphaComponent * 4)).setStroke()
            path.stroke()
        } else {
            let width = barWidth(fontSize)
            color.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: lines.minX, y: lines.minY, width: width, height: height),
                xRadius: width / 2, yRadius: width / 2
            ).fill()
        }
    }
}

extension PillLayoutManager {
    /// Quote bars and code block fills, under the pills and the text.
    func drawBlocks(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let all = NSRange(location: 0, length: storage.length)
        for key in [NSAttributedString.Key.codeBlock, .quoteBar] {
            storage.enumerateAttribute(key, in: characters) { value, range, _ in
                guard let color = value as? NSColor else { return }
                var block = NSRange()
                _ = storage.attribute(key, at: range.location, longestEffectiveRange: &block, in: all)
                var lines = NSRect.null
                enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: block, actualCharacterRange: nil)) {
                    fragment, _, _, _, _ in lines = lines.union(fragment)
                }
                guard !lines.isNull else { return }
                let style = storage.attribute(.paragraphStyle, at: block.location, effectiveRange: nil)
                let font = storage.attribute(.font, at: block.location, effectiveRange: nil) as? NSFont
                MessageBlocks.draw(
                    key, color: color, lines: lines.offsetBy(dx: origin.x, dy: origin.y),
                    style: style as? NSParagraphStyle, fontSize: font?.pointSize ?? NSFont.systemFontSize)
            }
        }
    }
}
