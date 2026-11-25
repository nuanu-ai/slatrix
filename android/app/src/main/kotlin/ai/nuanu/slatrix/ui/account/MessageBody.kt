package ai.nuanu.slatrix.ui.account

import kotlin.math.roundToInt

import androidx.compose.ui.text.TextLayoutResult

import androidx.compose.ui.layout.layout

import androidx.compose.ui.layout.VerticalAlignmentLine

import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.MessageBlock
import ai.nuanu.slatrix.core.MessageBodyRenderer
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageRun
import ai.nuanu.slatrix.core.MessageTextStyle
import ai.nuanu.slatrix.ui.designsystem.AppColors
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import ai.nuanu.slatrix.ui.designsystem.message
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.ResolvedTextDirection
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit

/** One line of a message, without its line break, and the block it sits in. */
private class Line(val runs: MutableList<MessageRun> = mutableListOf(), var block: MessageBlock? = null) {
    val marker get() = runs.firstOrNull()?.takeIf { it.marker }
}

/**
 * Lines that sit together: text, or a list item with its marker, which an item's continued text leaves empty. One
 * after a blank line starts a new paragraph, a short [gap] below the last instead of a whole empty line.
 */
private sealed interface Piece {
    val gap: Boolean
    data class Text(val lines: List<Line>, override val gap: Boolean = false) : Piece
    data class Item(val depth: Int, val marker: String, val lines: List<Line>, override val gap: Boolean = false) : Piece
}

private fun lines(runs: List<MessageRun>): List<Line> {
    val lines = mutableListOf(Line())
    for (run in runs) {
        run.text.split('\n').forEachIndexed { index, part ->
            if (index > 0) {
                // A line break belongs to the line it ends.
                lines.last().block = lines.last().block ?: run.block
                lines += Line()
            }
            if (part.isNotEmpty()) {
                lines.last().runs += run.copy(text = part)
                lines.last().block = lines.last().block ?: run.block
            }
        }
    }
    if (lines.size > 1 && lines.last().runs.isEmpty()) lines.removeAt(lines.lastIndex)
    return lines
}

private fun pieces(lines: List<Line>): List<Piece> {
    val pieces = mutableListOf<Piece>()
    var gap = false
    for (line in lines) {
        val depth = line.block?.list ?: 0
        val marker = line.marker
        val last = pieces.lastOrNull()
        // A code block keeps its blank lines as written.
        if (line.runs.isEmpty() && line.block?.code != true) {
            gap = pieces.isNotEmpty()
            continue
        }
        when {
            marker != null -> pieces += Piece.Item(depth, marker.text.trimEnd(), listOf(Line(line.runs.drop(1).toMutableList(), line.block)), gap)
            depth > 0 && !gap && last is Piece.Item && last.depth == depth -> pieces[pieces.lastIndex] = last.copy(lines = last.lines + line)
            depth > 0 -> pieces += Piece.Item(depth, "", listOf(line), gap)
            !gap && last is Piece.Text -> pieces[pieces.lastIndex] = last.copy(lines = last.lines + line)
            else -> pieces += Piece.Text(listOf(line), gap)
        }
        gap = false
    }
    return pieces
}

/** Lines in a quote, a code block, both or neither, grouped as the Mac draws them; a nested quote shows one bar. */
private fun groups(runs: List<MessageRun>): List<Pair<MessageBlock, List<Piece>>> =
    lines(runs).fold(mutableListOf<MutableList<Line>>()) { groups, line ->
        val last = groups.lastOrNull()?.last()?.block ?: MessageBlock()
        val block = line.block ?: MessageBlock()
        if (groups.isNotEmpty() && (last.quote > 0) == (block.quote > 0) && last.code == block.code) groups.last() += line
        else groups += mutableListOf(line)
        groups
    }.map { (it.first().block ?: MessageBlock()) to pieces(it) }

internal const val PILL_ANNOTATION_TAG = "slatrix.pill"
/** Narrow no-break space keeps rounded pill padding inside text layout so adjacent text and punctuation never collide. */
private const val PILL_PAD = "\u202F"
/** Breakable thin space separates immediately adjacent pills without gluing them together across line wraps. */
private const val PILL_SEPARATOR = "\u2009"

internal enum class PillKind(val annotation: String) {
    Mention("mention"),
    MentionYou("mention_you"),
    Code("code"),
}

internal data class TextPill(val start: Int, val end: Int, val kind: PillKind, val color: Color)

internal data class StyledMessageText(val text: AnnotatedString, val pills: List<TextPill>)

internal data class PillRect(val left: Float, val top: Float, val right: Float, val bottom: Float, val color: Color)

private fun pillIdentity(run: MessageRun, me: String?): Pair<String, PillKind>? = when {
    run.mention != null -> "m:${run.mention}" to if (run.mention == me || run.mention == "@room") PillKind.MentionYou else PillKind.Mention
    MessageTextStyle.Code in run.styles && !run.block.code -> "c" to PillKind.Code
    else -> null
}

private fun buildStyledText(
    lines: List<Line>,
    colors: AppColors,
    codeSize: TextUnit,
    emote: Boolean,
    edited: Boolean,
    editedFontSize: TextUnit,
    me: String?,
    onMention: ((String) -> Unit)?,
): StyledMessageText {
    val pills = mutableListOf<TextPill>()
    fun spanStyleFor(run: MessageRun, yours: Boolean): SpanStyle {
        val code = MessageTextStyle.Code in run.styles
        val decorations = listOfNotNull(
            TextDecoration.LineThrough.takeIf { MessageTextStyle.Strike in run.styles },
            TextDecoration.Underline.takeIf {
                MessageTextStyle.Underline in run.styles ||
                    run.link != null && run.mention == null && colors.underlineLinks
            },
        )
        return SpanStyle(
            color = when {
                run.mention != null -> if (yours) colors.mentionYouText else colors.mentionText
                run.link != null -> colors.accent
                else -> Color.Unspecified
            },
            fontWeight = FontWeight.Bold.takeIf { MessageTextStyle.Bold in run.styles },
            fontStyle = FontStyle.Italic.takeIf { MessageTextStyle.Italic in run.styles },
            fontFamily = FontFamily.Monospace.takeIf { code },
            fontSize = if (code) codeSize else TextUnit.Unspecified,
            textDecoration = decorations.takeIf { it.isNotEmpty() }?.let(TextDecoration::combine),
        )
    }

    fun AnnotatedString.Builder.appendLines() {
        lines.forEachIndexed { lineIndex, line ->
            if (lineIndex > 0) append('\n')
            var runIndex = 0
            var previousWasPill = false
            while (runIndex < line.runs.size) {
                val first = line.runs[runIndex]
                val identity = pillIdentity(first, me)
                if (identity == null) {
                    val style = spanStyleFor(first, yours = false)
                    val link = first.link
                    if (link != null) withLink(LinkAnnotation.Url(link, TextLinkStyles(style))) { append(first.text) }
                    else withStyle(style) { append(first.text) }
                    previousWasPill = false
                    runIndex++
                    continue
                }
                val (key, kind) = identity
                var groupEnd = runIndex + 1
                while (groupEnd < line.runs.size && pillIdentity(line.runs[groupEnd], me)?.first == key) groupEnd++
                val group = line.runs.subList(runIndex, groupEnd)
                if (previousWasPill) append(PILL_SEPARATOR)

                val yours = kind == PillKind.MentionYou
                val fill = when (kind) {
                    PillKind.MentionYou -> colors.mentionYouFill
                    PillKind.Mention -> colors.mentionFill
                    PillKind.Code -> colors.inlineCode
                }
                val person = first.mention?.takeIf { it != "@room" }
                val pillStart = length
                append(PILL_PAD)
                if (person != null && onMention != null) {
                    val linkColor = if (yours) colors.mentionYouText else colors.mentionText
                    // Keep link annotation strictly on the mention text so accessibility labels exclude padding chars.
                    withLink(LinkAnnotation.Clickable(person, TextLinkStyles(SpanStyle(color = linkColor))) { onMention(person) }) {
                        for (run in group) {
                            // A mention never breaks across lines, as a pill doesn't on the Mac.
                            val shown = run.text.replace(' ', '\u00A0').replace('-', '\u2011')
                            withStyle(spanStyleFor(run, yours)) { append(shown) }
                        }
                    }
                } else {
                    for (run in group) {
                        val shown = if (run.mention == null) run.text else run.text.replace(' ', '\u00A0').replace('-', '\u2011')
                        val runStyle = spanStyleFor(run, yours)
                        val link = run.link
                        if (link != null && run.mention == null) {
                            withLink(LinkAnnotation.Url(link, TextLinkStyles(runStyle))) { append(shown) }
                        } else {
                            withStyle(runStyle) { append(shown) }
                        }
                    }
                }
                append(PILL_PAD)
                val pillEnd = length
                addStringAnnotation(PILL_ANNOTATION_TAG, kind.annotation, pillStart, pillEnd)
                pills += TextPill(pillStart, pillEnd, kind, fill)
                previousWasPill = true
                runIndex = groupEnd
            }
        }
    }

    val text = buildAnnotatedString {
        if (emote) withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { appendLines() } else appendLines()
        if (edited) withStyle(SpanStyle(color = colors.textSecondary, fontSize = editedFontSize)) { append(" (edited)") }
    }
    return StyledMessageText(text, pills)
}

private class GlyphSpan(val left: Float, val right: Float, val startOffset: Int, val endOffset: Int)

/** Computes rounded pill rectangles per disjoint visual run on each line, handling wrapped and mixed-direction BiDi text. */
internal fun computePillRects(layout: TextLayoutResult, pills: List<TextPill>, wrapPadPx: Float): List<PillRect> {
    val text = layout.layoutInput.text
    if (pills.isEmpty() || layout.lineCount == 0 || text.isEmpty()) return emptyList()
    val maxWidth = layout.size.width.toFloat()
    val rects = ArrayList<PillRect>(pills.size)
    for (pill in pills) {
        val start = pill.start.coerceIn(0, text.length)
        val end = pill.end.coerceIn(0, text.length)
        if (start >= end) continue
        val firstLine = layout.getLineForOffset(start)
        val lastLine = layout.getLineForOffset(end - 1)
        for (line in firstLine..lastLine) {
            val lineStart = layout.getLineStart(line)
            val lineEnd = layout.getLineEnd(line, visibleEnd = true)
            var segStart = maxOf(start, lineStart)
            var segEnd = minOf(end, lineEnd)
            while (segEnd > segStart && text[segEnd - 1] == ' ') segEnd--
            if (segStart >= segEnd) continue

            // Collect non-empty character boxes and merge touching visual boxes so BiDi reordering never paints over plain text.
            val boxes = ArrayList<GlyphSpan>(segEnd - segStart)
            for (offset in segStart until segEnd) {
                val box = layout.getBoundingBox(offset)
                if (box.right > box.left) boxes += GlyphSpan(box.left, box.right, offset, offset + 1)
            }
            if (boxes.isEmpty()) continue
            boxes.sortBy { it.left }

            val merged = ArrayList<GlyphSpan>(2)
            for (span in boxes) {
                val prev = merged.lastOrNull()
                if (prev != null && span.left <= prev.right + BidiMergeTolerancePx) {
                    merged[merged.lastIndex] = GlyphSpan(
                        left = prev.left,
                        right = maxOf(prev.right, span.right),
                        startOffset = minOf(prev.startOffset, span.startOffset),
                        endOffset = maxOf(prev.endOffset, span.endOffset),
                    )
                } else {
                    merged += span
                }
            }

            val lineTop = layout.getLineTop(line)
            val lineBottom = layout.getLineBottom(line)
            val lineHeight = lineBottom - lineTop
            val vInset = (lineHeight * PillVerticalInsetRatio).coerceAtMost(lineHeight * 0.2f)
            val top = lineTop + vInset
            val bottom = lineBottom - vInset
            if (bottom <= top) continue

            val wrapsBefore = segStart > start
            val wrapsAfter = segEnd < end
            val startRtl = layout.getBidiRunDirection(segStart) == ResolvedTextDirection.Rtl
            val endRtl = layout.getBidiRunDirection(segEnd - 1) == ResolvedTextDirection.Rtl
            for (run in merged) {
                val padLeft = if ((wrapsBefore && !startRtl && segStart in run.startOffset until run.endOffset) ||
                    (wrapsAfter && endRtl && (segEnd - 1) in run.startOffset until run.endOffset)
                ) wrapPadPx else 0f
                val padRight = if ((wrapsAfter && !endRtl && (segEnd - 1) in run.startOffset until run.endOffset) ||
                    (wrapsBefore && startRtl && segStart in run.startOffset until run.endOffset)
                ) wrapPadPx else 0f
                val clampedLeft = (run.left - padLeft).coerceAtLeast(0f)
                val clampedRight = (run.right + padRight).coerceAtMost(maxWidth)
                if (clampedRight > clampedLeft) {
                    rects += PillRect(clampedLeft, top, clampedRight, bottom, pill.color)
                }
            }
        }
    }
    return rects
}

private const val PillVerticalInsetRatio = 0.05f
private const val BidiMergeTolerancePx = 1.5f

/** A message's text as Slack shows it: formatting, links, mention pills, quotes, lists and code blocks. */
@Composable
fun MessageBody(message: ConversationMessage, color: Color, me: String?, names: Map<String, String>, onMention: ((String) -> Unit)? = null) {
    val colors = SlatrixTheme.colors
    val textStyle = MaterialTheme.typography.message
    when (message.kind) {
        MessageKind.Deleted -> return Text(buildAnnotatedString {
            withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append("This message was deleted.") }
        }, style = textStyle, color = colors.textSecondary)
        MessageKind.Encrypted -> return Row(verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
            val secondary = MaterialTheme.typography.bodyMedium
            Icon(Icons.Outlined.Lock, null, Modifier.size(with(LocalDensity.current) { secondary.fontSize.toDp() }), tint = colors.textSecondary)
            Text(buildAnnotatedString { withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(message.body) } },
                style = secondary, color = colors.textSecondary)
        }
        else -> {}
    }
    val hasMentions = remember(message.runs) { message.runs.any { it.mention != null } }
    val mentionNames = if (hasMentions) names else emptyMap()
    val groups = remember(message.runs, mentionNames) { groups(MessageBodyRenderer.named(message.runs, mentionNames)) }
    // The marker fills the list indent, so a wrapped line starts under the item's first word, as on the Mac.
    val indent = with(LocalDensity.current) { (textStyle.fontSize * UiMetrics.ListIndentScale).toDp() }
    // Slack ends an edited message's last line with a quiet "(edited)", or puts it under a code block.
    val editedBelow = message.edited && groups.lastOrNull()?.first?.code == true
    Column(verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
        groups.forEachIndexed { index, (block, pieces) ->
            val content = @Composable {
                MessagePieces(pieces, colors, color, textStyle, indent, me, message.kind == MessageKind.Emote,
                    message.edited && !editedBelow && index == groups.lastIndex, onMention,
                    endsMessage = index == groups.lastIndex && !block.code && !editedBelow)
            }
            val text = @Composable {
                if (block.code) Surface(Modifier.padding(start = indent * block.list).fillMaxWidth(), shape = MaterialTheme.shapes.small,
                    color = colors.codeBlock, border = BorderStroke(UiMetrics.Divider, colors.codeBlockEdge)) {
                    Box(Modifier.padding(UiMetrics.GapSmall)) { content() }
                } else content()
            }
            if (block.quote > 0) Row(Modifier.height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
                Box(Modifier.width(UiMetrics.QuoteBar).fillMaxHeight().background(colors.quoteBar, MaterialTheme.shapes.extraSmall))
                text()
            } else text()
        }
        if (editedBelow) Text("(edited)", style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
    }
}

/** Where a message's last line of text ends, so its time can follow it on that line. */
internal val LastLineEnd = VerticalAlignmentLine { _, last -> last }

/** Gives [LastLineEnd] as where the laid out text's last line ends. */
private fun Modifier.endsLastLine(text: () -> TextLayoutResult?) = layout { measurable, constraints ->
    val placeable = measurable.measure(constraints)
    val end = text()?.let { it.getLineRight(it.lineCount - 1).roundToInt() } ?: placeable.width
    layout(placeable.width, placeable.height, mapOf(LastLineEnd to end)) { placeable.place(0, 0) }
}

@Composable
private fun MessagePieces(pieces: List<Piece>, colors: AppColors, color: Color, style: TextStyle, indent: Dp, me: String?,
    emote: Boolean, edited: Boolean, onMention: ((String) -> Unit)?, endsMessage: Boolean) {
    val caption = MaterialTheme.typography.bodySmall
    val codeSize = style.fontSize * UiMetrics.CodeTextScale
    // Kept without state: read only while laying out, just after the text it holds was measured.
    val laidOut = remember { arrayOfNulls<TextLayoutResult>(1) }
    Column {
        pieces.forEachIndexed { index, piece ->
            val last = index == pieces.lastIndex
            val top = if (piece.gap) Modifier.padding(top = UiMetrics.GapSmall) else Modifier
            val ends = if (last && endsMessage) Modifier.endsLastLine { laidOut[0] } else Modifier
            val lines = when (piece) {
                is Piece.Text -> piece.lines
                is Piece.Item -> piece.lines
            }
            val styled = remember(lines, colors, codeSize, emote, edited, last, caption.fontSize, me, onMention) {
                buildStyledText(lines, colors, codeSize, emote, edited && last, caption.fontSize, me, onMention)
            }
            when (piece) {
                is Piece.Text -> PillText(styled, top.then(ends), style, color) { if (last) laidOut[0] = it }
                is Piece.Item -> Row(top.padding(start = indent * (piece.depth - 1))) {
                    Text(piece.marker, Modifier.widthIn(min = indent), style = style, color = color)
                    PillText(styled, ends, style, color) { if (last) laidOut[0] = it }
                }
            }
        }
    }
}

@Composable
private fun PillText(styled: StyledMessageText, modifier: Modifier, style: TextStyle, color: Color,
    onLayout: (TextLayoutResult) -> Unit) {
    val pillCorner = MaterialTheme.shapes.extraSmall
    var drawLayout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val drawPills = if (styled.pills.isEmpty()) Modifier else Modifier.drawBehind {
        val layout = drawLayout ?: return@drawBehind
        // Compare plain text because TextLinkScope expands LinkAnnotation styles into a distinct AnnotatedString.
        if (layout.layoutInput.text.text != styled.text.text) return@drawBehind
        val radius = pillCorner.topStart.toPx(size, this)
        val cornerRadius = CornerRadius(radius, radius)
        val wrapPad = UiMetrics.LineGap.toPx()
        for (rect in computePillRects(layout, styled.pills, wrapPad)) {
            drawRoundRect(
                color = rect.color,
                topLeft = Offset(rect.left, rect.top),
                size = Size(rect.right - rect.left, rect.bottom - rect.top),
                cornerRadius = cornerRadius,
            )
        }
    }
    Text(
        styled.text,
        modifier.then(drawPills),
        style = style,
        color = color,
        onTextLayout = { result ->
            if (styled.pills.isNotEmpty()) drawLayout = result
            onLayout(result)
        },
    )
}
