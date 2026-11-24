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
    /// Line spacing for reading text (~21 pt lines at the 14 pt reading size), shared by timeline and composer.
    static func readingLineSpacing(_ fontSize: CGFloat) -> CGFloat { fontSize * 0.27 }
    /// Space after an explicit paragraph break (`\n`) on non-code paragraphs, distinct from soft-wrapped lines.
    static func paragraphSpacing(_ fontSize: CGFloat) -> CGFloat { fontSize * 0.25 }

    /// h1 and h2 on the macOS title sizes, and h3 to h6 a step above the reading size, scaled from `fontSize`, the
    /// reading size at the current zoom.
    static func headingSize(_ level: Int, _ fontSize: CGFloat) -> CGFloat {
        let role: TextRole = level == 1 ? .title1 : level == 2 ? .title2 : .title3
        return fontSize * role.points / TextRole.reading.points
    }

    /// A list marker and the space after it, in `attributes`, with a bullet in a heavier weight so it reads at any
    /// zoom.
    static func marker(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
        let marker = NSMutableAttributedString(string: text, attributes: attributes)
        if text.hasPrefix("•"), let font = attributes[.font] as? NSFont {
            marker.addAttribute(
                .font, value: NSFont.systemFont(ofSize: font.pointSize, weight: .heavy),
                range: NSRange(location: 0, length: 1))
        }
        return marker
    }

    /// A line's style. `marker`: the width of the list marker the line starts with, which hangs in the indent.
    /// `heading`: the line is a heading below other lines, with a gap above it.
    static func paragraph(
        quote: Bool, list: Int, code: Bool, marker: CGFloat = 0, heading: Bool = false, fontSize: CGFloat,
        lineSpacing: CGFloat
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        if !code {
            style.paragraphSpacing = paragraphSpacing(fontSize)
            style.lineBreakStrategy = .pushOut
        }
        let indent =
            (quote ? quoteIndent(fontSize) : 0) + CGFloat(list) * listIndent(fontSize)
            + (code ? codePadding(fontSize) : 0)
        // A marker wider than its list's indent pushes the item's text over, clear of what is outside the list.
        style.firstLineHeadIndent = indent - min(marker, listIndent(fontSize))
        style.headIndent = max(indent, style.firstLineHeadIndent + marker)
        if code { style.tailIndent = -codePadding(fontSize) }
        if heading { style.paragraphSpacingBefore = fontSize * Metrics().sp8 / TextRole.reading.points }
        return style
    }

    /// Shrinks each blank line between paragraphs to a small gap, as Slack spaces them, keeping the text as written so
    /// a copy still has its blank lines. Code blocks keep theirs.
    static func shrinkBlankLines(_ text: NSMutableAttributedString, fontSize: CGFloat) {
        let string = text.string as NSString
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]
        ) { _, line, enclosing, _ in
            guard line.length == 0, enclosing.length > 0,
                text.attribute(.codeBlock, at: enclosing.location, effectiveRange: nil) == nil,
                let style =
                    (text.attribute(.paragraphStyle, at: enclosing.location, effectiveRange: nil)
                    as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            else { return }
            style.lineSpacing = 0
            style.paragraphSpacing = 0
            style.minimumLineHeight = fontSize * 0.5
            style.maximumLineHeight = fontSize * 0.5
            text.addAttribute(.paragraphStyle, value: style, range: enclosing)
        }
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
            let before = first ? codePadding(fontSize) : 0
            let after = last ? codePadding(fontSize) : 0
            // An unchanged block must not count as edited, or the caret jumps to its end.
            guard style.paragraphSpacingBefore != before || style.paragraphSpacing != after else { return }
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            text.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
    }

    /// A quote's bar or a code block's fill beside or behind `lines`, the union of the block's line fragments.
    static func draw(
        _ key: NSAttributedString.Key, color: NSColor, lines: NSRect, style: NSParagraphStyle?, fontSize: CGFloat
    ) {
        let trailingGap = (style?.lineSpacing ?? 0) + (key == .codeBlock ? 0 : (style?.paragraphSpacing ?? 0))
        let height = lines.height - trailingGap
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
