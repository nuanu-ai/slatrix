package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.ComposerFormat
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationRow
import ai.nuanu.slatrix.core.MessageReaction
import ai.nuanu.slatrix.core.MessageThread
import ai.nuanu.slatrix.ui.designsystem.BottomSheet
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import android.text.format.DateUtils
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight

/** Slack's reaction chips under a message: a tap adds or takes back yours, a long press shows who reacted. */
@OptIn(ExperimentalLayoutApi::class, ExperimentalFoundationApi::class)
@Composable
internal fun Reactions(reactions: List<MessageReaction>, onToggle: ((String) -> Unit)?, onShowWho: () -> Unit) {
    val colors = SlatrixTheme.colors
    FlowRow(Modifier.padding(top = UiMetrics.GapSmall), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall),
        verticalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
        for (reaction in reactions) {
            Row(Modifier.height(UiMetrics.ChipHeight)
                .background(if (reaction.mine) colors.accentTint else colors.sunken, CircleShape)
                .border(BorderStroke(UiMetrics.Divider, if (reaction.mine) colors.accent else colors.sunken), CircleShape)
                .semantics { selected = reaction.mine }
                .combinedClickable(onLongClickLabel = "See who reacted", onLongClick = onShowWho) { onToggle?.invoke(reaction.key) }
                .padding(horizontal = UiMetrics.GapMedium),
                horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny), verticalAlignment = Alignment.CenterVertically) {
                Text(reaction.key, style = MaterialTheme.typography.bodyLarge)
                Text("${reaction.count}", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Medium,
                    color = if (reaction.mine) colors.accent else colors.textPrimary)
            }
        }
    }
}

/** Slack's line under a thread's root: who replied last, how many replies and when; a tap opens the thread. */
@Composable
internal fun ThreadReplies(thread: MessageThread, onOpen: (() -> Unit)?) {
    val colors = SlatrixTheme.colors
    Row(Modifier.padding(top = UiMetrics.GapTiny).heightIn(min = UiMetrics.ChipHeight)
        .then(if (onOpen != null) Modifier.clickable(onClickLabel = "View thread", onClick = onOpen) else Modifier),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
        thread.lastReplier?.let {
            LiveAvatar(AvatarPlaceholder.initials(it), AvatarPlaceholder.colorIndex(it), UiMetrics.CompactAvatar, thread.lastReplierAvatarUrl)
        }
        Text("${thread.replies} ${if (thread.replies == 1) "reply" else "replies"}", style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.Bold, color = colors.accent, maxLines = 1)
        thread.lastReplyAt?.let { at ->
            val now = System.currentTimeMillis()
            Text(remember(at) { lastReply(at, now) }, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary, maxLines = 1)
        }
    }
}

/** "Last reply 2 hours ago", as Slack and the Mac put it. */
private fun lastReply(at: Long, now: Long): String =
    if (now - at < DateUtils.MINUTE_IN_MILLIS) "Last reply just now"
    else "Last reply " + DateUtils.getRelativeTimeSpanString(at, now, DateUtils.MINUTE_IN_MILLIS)

/** Who reacted with each emoji, named as they appear in the conversation, with you as "You". */
@Composable
internal fun ReactionsSheet(reactions: List<MessageReaction>, rows: List<ConversationRow>, me: String?, onDismiss: () -> Unit) {
    val colors = SlatrixTheme.colors
    val names = remember(rows) { rows.filterIsInstance<ConversationMessage>().associate { it.senderId to it.senderName } }
    BottomSheet(onDismissRequest = onDismiss, containerColor = colors.overlay) {
        Column(Modifier.fillMaxWidth().padding(bottom = UiMetrics.GapLarge)) {
            for (reaction in reactions) {
                val who = reaction.senders.map { if (it == me) "You" else names[it] ?: ComposerFormat.localpart(it) }
                Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).padding(horizontal = UiMetrics.GapLarge),
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                    Text(reaction.key, style = MaterialTheme.typography.headlineSmall)
                    Text(if (who.size > 1) who.dropLast(1).joinToString(", ") + " and " + who.last() else who.joinToString(),
                        style = MaterialTheme.typography.bodyLarge, color = colors.textPrimary)
                }
            }
        }
    }
}
