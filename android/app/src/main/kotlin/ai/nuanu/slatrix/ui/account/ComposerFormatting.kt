package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ComposerMention
import ai.nuanu.slatrix.core.ComposerStyle
import ai.nuanu.slatrix.core.ComposerStyle.Kind
import ai.nuanu.slatrix.core.ComposerStyles
import ai.nuanu.slatrix.ui.designsystem.AppColors
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.FormatListBulleted
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.DataObject
import androidx.compose.material.icons.outlined.FormatBold
import androidx.compose.material.icons.outlined.FormatItalic
import androidx.compose.material.icons.outlined.FormatListNumbered
import androidx.compose.material.icons.outlined.FormatQuote
import androidx.compose.material.icons.outlined.FormatStrikethrough
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.style.TextDecoration

/** Slack's "Aa" button, which swaps the composer's toolbar for its formats. */
@Composable
fun FormattingToggle(on: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    IconButton(onClick = onClick, enabled = enabled, modifier = Modifier.semantics { contentDescription = "Formatting" }) {
        Text("Aa", style = MaterialTheme.typography.titleMedium, color = if (on) colors.accent else colors.textPrimary)
    }
}

/** The formats in Slack's order, each marked while it is on where you type. */
@Composable
fun RowScope.FormattingBar(active: Set<Kind>, enabled: Boolean, onFormat: (Kind) -> Unit, onLink: () -> Unit) {
    val colors = SlatrixTheme.colors
    @Composable
    fun button(icon: ImageVector, label: String, kind: Kind?) = IconButton(onClick = { if (kind == null) onLink() else onFormat(kind) },
        enabled = enabled) {
        Icon(icon, label, tint = if (kind in active) colors.accent else colors.textPrimary)
    }
    Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically) {
        button(Icons.Outlined.FormatBold, "Bold", Kind.Bold)
        button(Icons.Outlined.FormatItalic, "Italic", Kind.Italic)
        button(Icons.Outlined.FormatStrikethrough, "Strikethrough", Kind.Strike)
        button(Icons.Outlined.Link, "Link", null)
        button(Icons.Outlined.FormatListNumbered, "Numbered list", Kind.Numbered)
        button(Icons.AutoMirrored.Outlined.FormatListBulleted, "Bulleted list", Kind.Bullet)
        button(Icons.Outlined.FormatQuote, "Quote", Kind.Quote)
        button(Icons.Outlined.Code, "Code", Kind.Code)
        button(Icons.Outlined.DataObject, "Code block", Kind.CodeBlock)
    }
}

/** Slack's link sheet; with nothing selected it asks for the text too. [onSave] gets the text, if asked, and the address. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LinkSheet(askText: Boolean, onSave: (text: String?, href: String) -> Unit, onDismiss: () -> Unit) {
    val colors = SlatrixTheme.colors
    var text by rememberSaveable { mutableStateOf("") }
    var link by rememberSaveable { mutableStateOf("") }
    val href = link.trim().let { if (it.isEmpty() || it.contains(':')) it else "https://$it" }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        shape = SlatrixTheme.topPanelShape, containerColor = colors.canvas) {
        Column(Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge).padding(bottom = UiMetrics.GapLarge),
            verticalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Add link", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                TextButton(onClick = { onSave(text.takeIf { askText }?.ifBlank { href }, href) }, enabled = href.isNotEmpty()) { Text("Save") }
            }
            if (askText) OutlinedTextField(text, { text = it }, Modifier.fillMaxWidth(), label = { Text("Text") }, singleLine = true)
            OutlinedTextField(link, { link = it }, Modifier.fillMaxWidth(), label = { Text("Link") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
        }
    }
}

/**
 * Draws the composer's formats, pills and block markers over its plain text, so the field edits only what is sent. A
 * marker sits before its line and maps to the line's start.
 */
class ComposerVisual(private val styles: List<ComposerStyle>, private val mentions: List<ComposerMention>,
    private val colors: AppColors) : VisualTransformation {
    override fun filter(text: AnnotatedString): TransformedText {
        val raw = text.text
        val starts = generateSequence(0) { start -> raw.indexOf('\n', start).takeIf { it >= 0 }?.plus(1) }.toList()
        val markers = mutableListOf<Pair<Int, Int>>()
        var number = 0
        val shown = buildAnnotatedString {
            for (start in starts) {
                val end = raw.indexOf('\n', start).let { if (it < 0) raw.length else it }
                val block = ComposerStyles.blockOf(styles, raw, start)
                number = if (block == Kind.Numbered) number + 1 else 0
                val marker = when (block) {
                    Kind.Bullet -> "•  "
                    Kind.Numbered -> "$number. "
                    Kind.Quote -> "┃ "
                    else -> ""
                }
                if (marker.isNotEmpty()) {
                    pushStyle(SpanStyle(color = colors.textSecondary))
                    append(marker)
                    pop()
                    markers += start to marker.length
                }
                val offset = length - start
                append(raw.substring(start, end))
                if (block == Kind.CodeBlock) addStyle(SpanStyle(fontFamily = FontFamily.Monospace, background = colors.inlineCode), start + offset, end + offset)
                for (style in styles) {
                    val from = maxOf(style.start, start)
                    val to = minOf(style.end, end)
                    if (style.kind.block || from >= to) continue
                    addStyle(span(style.kind), from + offset, to + offset)
                }
                for (mention in mentions) {
                    if (mention.start >= start && mention.end <= end)
                        addStyle(SpanStyle(color = colors.mentionText, background = colors.mentionFill), mention.start + offset, mention.end + offset)
                }
                if (end < raw.length) append('\n')
            }
        }
        val mapping = object : OffsetMapping {
            override fun originalToTransformed(offset: Int) = offset + markers.sumOf { (at, length) -> if (at <= offset) length else 0 }
            override fun transformedToOriginal(offset: Int): Int {
                var shift = 0
                for ((at, length) in markers) {
                    if (at + shift + length > offset) return if (at + shift <= offset) at else offset - shift
                    shift += length
                }
                return offset - shift
            }
        }
        return TransformedText(shown, mapping)
    }

    private fun span(kind: Kind) = when (kind) {
        Kind.Bold -> SpanStyle(fontWeight = FontWeight.Bold)
        Kind.Italic -> SpanStyle(fontStyle = FontStyle.Italic)
        Kind.Strike -> SpanStyle(textDecoration = TextDecoration.LineThrough)
        Kind.Code -> SpanStyle(fontFamily = FontFamily.Monospace, background = colors.inlineCode)
        Kind.Link -> SpanStyle(color = colors.accent, textDecoration = TextDecoration.Underline)
        else -> SpanStyle()
    }

    override fun equals(other: Any?) = other is ComposerVisual && other.styles == styles && other.mentions == mentions && other.colors == colors
    override fun hashCode() = styles.hashCode() * 31 + mentions.hashCode()
}
