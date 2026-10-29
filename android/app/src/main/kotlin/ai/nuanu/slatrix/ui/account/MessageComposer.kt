package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ComposerTarget
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow

/** What the composer can do beyond typing and sending. */
data class ComposerActions(
    val onCancelTarget: () -> Unit = {},
)

/** Slack's composer: a rounded field on a bar under a hairline, with send inside the field. */
@Composable
internal fun MessageComposer(room: RoomSummary, composer: ComposerState, onDraft: (String) -> Unit, onSend: () -> Unit,
    actions: ComposerActions) {
    val colors = SlatrixTheme.colors
    val description = if (room.direct) "Message ${room.name}" else "Message #${room.name}"
    val editing = composer.target is ComposerTarget.Edit
    HorizontalDivider(color = colors.border)
    composer.target?.let { TargetBar(it, actions.onCancelTarget) }
    Surface(Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapMedium, vertical = UiMetrics.GapSmall),
        shape = MaterialTheme.shapes.extraLarge, color = colors.raised) {
        Row(verticalAlignment = Alignment.Bottom) {
            BasicTextField(composer.text, onDraft, enabled = !composer.loading,
                modifier = Modifier.weight(1f).heightIn(min = UiMetrics.Touch).padding(start = UiMetrics.GapMedium)
                    .semantics { contentDescription = description },
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.textBody),
                cursorBrush = SolidColor(colors.accent), maxLines = 5,
                decorationBox = { inner ->
                    Box(Modifier.padding(vertical = UiMetrics.GapMedium), contentAlignment = Alignment.CenterStart) {
                        if (composer.text.isEmpty()) Text(description, style = MaterialTheme.typography.bodyLarge,
                            color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        inner()
                    }
                })
            IconButton(onClick = onSend, enabled = !composer.loading && !composer.sending && composer.text.isNotBlank()) {
                Icon(if (editing) Icons.Outlined.Check else Icons.AutoMirrored.Outlined.Send,
                    if (editing) "Save changes" else "Send message",
                    tint = if (composer.text.isNotBlank()) colors.accent else colors.textTertiary)
            }
        }
    }
}

/** The bar over the field while a send quotes a message or replaces your own, as on the Mac. */
@Composable
private fun TargetBar(target: ComposerTarget, onCancel: () -> Unit) {
    val colors = SlatrixTheme.colors
    val reply = target as? ComposerTarget.Reply
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).padding(start = UiMetrics.GapLarge, top = UiMetrics.GapSmall),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(UiMetrics.QuoteBar).fillMaxHeight().background(colors.accent, MaterialTheme.shapes.small))
        Column(Modifier.weight(1f)) {
            Text(if (reply != null) "Replying to ${reply.senderName}" else "Editing message",
                style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, color = colors.textPrimary,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (reply != null) Text(reply.body, style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        IconButton(onClick = onCancel) {
            Icon(Icons.Outlined.Close, if (reply != null) "Cancel reply" else "Cancel editing", Modifier.size(UiMetrics.Icon),
                tint = colors.textSecondary)
        }
    }
}
