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
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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

private fun AnnotatedString.Builder.append(lines: List<Line>, colors: AppColors, codeSize: TextUnit, me: String?,
    onMention: ((String) -> Unit)?) {
    lines.forEachIndexed { index, line ->
        if (index > 0) append('\n')
        var previous: String? = null
        for (run in line.runs) {
            // Mentions side by side keep a thin gap, where the line may break, so each reads as its own pill.
            if (run.mention != null && previous != null && previous != run.mention) append('\u2009')
            previous = run.mention
            val code = MessageTextStyle.Code in run.styles
            // A mention of you or of everyone stands out, as on the Mac.
            val yours = run.mention == me || run.mention == "@room"
            val decorations = listOfNotNull(
                TextDecoration.LineThrough.takeIf { MessageTextStyle.Strike in run.styles },
                TextDecoration.Underline.takeIf { MessageTextStyle.Underline in run.styles ||
                    run.link != null && run.mention == null && colors.underlineLinks },
            )
            val style = SpanStyle(
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
                background = when {
                    run.mention != null -> if (yours) colors.mentionYouFill else colors.mentionFill
                    code && !run.block.code -> colors.inlineCode
                    else -> Color.Unspecified
                },
            )
            val link = run.link
            val person = run.mention?.takeIf { it != "@room" }
            // A name never breaks across lines, as a pill doesn't on the Mac.
            val text = if (run.mention == null) run.text else run.text.replace(' ', '\u00A0').replace('-', '\u2011')
            if (link != null && run.mention == null) withLink(LinkAnnotation.Url(link, TextLinkStyles(style))) { append(text) }
            else if (person != null && onMention != null) withLink(LinkAnnotation.Clickable(person, TextLinkStyles(style)) { onMention(person) }) { append(text) }
            else withStyle(style) { append(text) }
        }
    }
}

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
    val groups = remember(message.runs, names) { groups(MessageBodyRenderer.named(message.runs, names)) }
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
    fun text(lines: List<Line>, last: Boolean) = buildAnnotatedString {
        val codeSize = style.fontSize * UiMetrics.CodeTextScale
        if (emote) withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(lines, colors, codeSize, me, onMention) } else append(lines, colors, codeSize, me, onMention)
        if (edited && last) withStyle(SpanStyle(color = colors.textSecondary, fontSize = caption.fontSize)) { append(" (edited)") }
    }
    // Kept without state: read only while laying out, just after the text it holds was measured.
    val laidOut = remember { arrayOfNulls<TextLayoutResult>(1) }
    Column {
        pieces.forEachIndexed { index, piece ->
            val last = index == pieces.lastIndex
            val top = if (piece.gap) Modifier.padding(top = UiMetrics.GapSmall) else Modifier
            val ends = if (last && endsMessage) Modifier.endsLastLine { laidOut[0] } else Modifier
            val onLayout: (TextLayoutResult) -> Unit = { if (last) laidOut[0] = it }
            when (piece) {
                is Piece.Text -> Text(text(piece.lines, last), top.then(ends), style = style, color = color, onTextLayout = onLayout)
                is Piece.Item -> Row(top.padding(start = indent * (piece.depth - 1))) {
                    Text(piece.marker, Modifier.widthIn(min = indent), style = style, color = color)
                    Text(text(piece.lines, last), ends, style = style, color = color, onTextLayout = onLayout)
                }
            }
        }
    }
}
