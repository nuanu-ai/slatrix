package ai.nuanu.slatrix.ui.account

import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextOverflow
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import androidx.compose.material3.Icon
import androidx.compose.material3.HorizontalDivider
import ai.nuanu.slatrix.core.DisplayNames
import ai.nuanu.slatrix.core.MessageReaction
import ai.nuanu.slatrix.core.MessageThread
import ai.nuanu.slatrix.ui.designsystem.BottomSheet
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import android.text.format.DateUtils
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
import androidx.compose.ui.graphics.compositeOver

/**
 * Slack's reaction chips under a message: a tap adds or takes back yours, a long press shows who reacted. A chip shows
 * the faces of who reacted in place of its count, by the shared rule, from [avatars] by user ID over their initials.
 */
@OptIn(ExperimentalLayoutApi::class, ExperimentalFoundationApi::class)
@Composable
internal fun Reactions(reactions: List<MessageReaction>, me: String?, names: Map<String, String>, avatars: Map<String, String>,
    onToggle: ((String) -> Unit)?, onShowWho: () -> Unit) {
    val colors = SlatrixTheme.colors
    FlowRow(Modifier.padding(top = UiMetrics.GapSmall), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall),
        verticalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
        for (reaction in reactions) {
            // Yours is tinted with the accent, as on the Mac; opaque, so the faces' rings match the chip.
            val fill = (if (reaction.mine) colors.accentTint else colors.reaction).compositeOver(colors.bubbleIn)
            Row(Modifier.height(UiMetrics.ChipHeight)
                .background(fill, CircleShape)
                // Your own bubble tints every chip alike, so there yours also wears an edge in the accent, white there.
                .then(if (reaction.mine && colors.accentTint == colors.reaction) Modifier.border(UiMetrics.Divider, colors.accent, CircleShape)
                    else Modifier)
                .semantics { selected = reaction.mine }
                .combinedClickable(onLongClickLabel = "See who reacted", onLongClick = onShowWho) { onToggle?.invoke(reaction.key) }
                .padding(horizontal = UiMetrics.GapSmall),
                horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny), verticalAlignment = Alignment.CenterVertically) {
                Text(reaction.key, style = MaterialTheme.typography.bodyLarge)
                val faces = reaction.faces(me)
                // Overlapping, each ringed in the chip's fill so the one beneath shows where it ends.
                if (faces != null) Row(Modifier.semantics { contentDescription = who(faces, names, me) },
                    horizontalArrangement = Arrangement.spacedBy(-UiMetrics.GapTiny)) {
                    for (id in faces) {
                        val name = names[id] ?: DisplayNames.localpart(id)
                        Box(Modifier.border(UiMetrics.FaceRing, fill, CircleShape)) {
                            LiveAvatar(name, UiMetrics.Facepile, avatars[id])
                        }
                    }
                } else Text("${reaction.count}", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Medium,
                    color = if (reaction.mine) colors.accent else colors.textPrimary)
            }
        }
    }
}

/** The bar at the foot of a thread's root bubble: who replied last, how many replies and when; a tap opens the thread. */
@Composable
internal fun ThreadReplies(thread: MessageThread, onOpen: (() -> Unit)?) {
    val colors = SlatrixTheme.colors
    Column(Modifier.padding(top = UiMetrics.GapSmall)) {
        HorizontalDivider(color = colors.border)
        Row(Modifier.heightIn(min = UiMetrics.ThreadBar)
            .then(if (onOpen != null) Modifier.clickable(onClickLabel = "View thread", onClick = onOpen) else Modifier),
            horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
            thread.lastReplier?.let {
                LiveAvatar(it, UiMetrics.Facepile, thread.lastReplierAvatarUrl)
            }
            Text("${thread.replies} ${if (thread.replies == 1) "reply" else "replies"}", style = MaterialTheme.typography.labelLarge,
                color = colors.accent, maxLines = 1)
            thread.lastReplyAt?.let { at ->
                val now = System.currentTimeMillis()
                Text(remember(at) { lastReply(at, now) }, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.labelSmall,
                    color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (onOpen != null) Icon(SlackIcons.ChevronRight, null, Modifier.size(UiMetrics.Icon), tint = colors.textSecondary)
        }
    }
}

/** "Last reply 2 hours ago", as Slack and the Mac put it. */
private fun lastReply(at: Long, now: Long): String =
    if (now - at < DateUtils.MINUTE_IN_MILLIS) "Last reply just now"
    else "Last reply " + DateUtils.getRelativeTimeSpanString(at, now, DateUtils.MINUTE_IN_MILLIS)

/** Who reacted with each emoji, by the [names] the room knows them by, with you as "You". */
@Composable
internal fun ReactionsSheet(reactions: List<MessageReaction>, names: Map<String, String>, me: String?, onDismiss: () -> Unit) {
    val colors = SlatrixTheme.colors
    BottomSheet(onDismissRequest = onDismiss, containerColor = colors.overlay) {
        Column(Modifier.fillMaxWidth().padding(bottom = UiMetrics.GapLarge)) {
            for (reaction in reactions) {
                Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).padding(horizontal = UiMetrics.GapLarge),
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                    Text(reaction.key, style = MaterialTheme.typography.headlineSmall)
                    Text(who(reaction.senders, names, me), style = MaterialTheme.typography.bodyLarge, color = colors.textPrimary)
                }
            }
        }
    }
}

/** "Mira, You and sam": [ids] by the names the room knows them by, with you as "You". */
private fun who(ids: List<String>, names: Map<String, String>, me: String?): String {
    val who = ids.map { if (it == me) "You" else names[it] ?: DisplayNames.localpart(it) }
    return if (who.size > 1) who.dropLast(1).joinToString(", ") + " and " + who.last() else who.joinToString()
}
