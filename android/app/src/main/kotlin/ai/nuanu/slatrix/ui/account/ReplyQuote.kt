package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ReplyPreview
import ai.nuanu.slatrix.core.ThreadOrigin
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow

/**
 * The message a reply answers, quoted above it as on the Mac: who sent it and its first line. Every state takes the
 * loaded quote's two lines, so the row keeps its height when the parent lands; a tap jumps to the parent.
 */
@Composable
internal fun ReplyQuote(reply: ReplyPreview, onOpen: () -> Unit) {
    val colors = SlatrixTheme.colors
    val ready = reply.state == ReplyPreview.State.Ready
    QuoteLines(ready, "Show original message", onOpen) {
        Text(if (ready) reply.senderName else " ", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold,
            color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(when (reply.state) {
            ReplyPreview.State.Ready -> reply.body
            ReplyPreview.State.Unavailable -> "Original message unavailable"
            ReplyPreview.State.Loading -> " "
        }, style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/**
 * Slack's line on a channel's copy of a thread reply, in a quote's two lines: "replied to a thread:" and the thread's
 * first message, held blank until [origin] is known; a tap opens the thread.
 */
@Composable
internal fun ThreadCopyQuote(origin: ThreadOrigin?, onOpen: ((String) -> Unit)?) {
    val colors = SlatrixTheme.colors
    QuoteLines(origin != null && onOpen != null, "View thread", { origin?.let { onOpen?.invoke(it.rootId) } }) {
        Text("replied to a thread:", style = MaterialTheme.typography.labelLarge, color = colors.textSecondary, maxLines = 1)
        Text(origin?.preview ?: " ", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, color = colors.accent,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun QuoteLines(enabled: Boolean, label: String, onOpen: () -> Unit, lines: @Composable () -> Unit) {
    val colors = SlatrixTheme.colors
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).padding(vertical = UiMetrics.GapTiny)
        .clickable(enabled = enabled, onClickLabel = label, onClick = onOpen),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        Box(Modifier.width(UiMetrics.QuoteBar).fillMaxHeight().background(colors.quoteBar, MaterialTheme.shapes.extraSmall))
        Column { lines() }
    }
}
