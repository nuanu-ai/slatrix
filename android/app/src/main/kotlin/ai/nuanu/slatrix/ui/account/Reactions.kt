package ai.nuanu.slatrix.ui.account

import androidx.compose.foundation.layout.size
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextOverflow
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import androidx.compose.material3.Icon
import androidx.compose.material3.HorizontalDivider
import ai.nuanu.slatrix.core.DisplayNames
import ai.nuanu.slatrix.core.MessageReaction
import ai.nuanu.slatrix.core.MessageThread
import ai.nuanu.slatrix.ui.designsystem.BottomSheet
import ai.nuanu.slatrix.ui.designsystem.Motion
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import ai.nuanu.slatrix.ui.designsystem.isMotionReduced
import android.text.format.DateUtils
import androidx.compose.animation.core.Animatable
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight

/**
 * Slack's reaction chips under a message, each its emoji and count: a tap adds or takes back yours, a long press shows
 * who reacted. Chips already on a message stay still as history scrolls; newly added or toggled chips spring-pop in.
 */
@OptIn(ExperimentalLayoutApi::class, ExperimentalFoundationApi::class)
@Composable
internal fun Reactions(reactions: List<MessageReaction>, me: String?, names: Map<String, String>,
    onToggle: ((String) -> Unit)?, onShowWho: () -> Unit) {
    val colors = SlatrixTheme.colors
    val context = LocalContext.current
    val mounted = remember { reactions.mapTo(mutableSetOf()) { it.key } }
    FlowRow(Modifier.padding(top = UiMetrics.GapSmall), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall),
        verticalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
        for (reaction in reactions) {
            key(reaction.key) {
                val existed = remember { reaction.key in mounted }
                val scale = remember { Animatable(if (existed) 1f else 0.6f) }
                LaunchedEffect(Unit) {
                    mounted += reaction.key
                    if (!existed) {
                        if (coroutineContext.isMotionReduced(context)) scale.snapTo(1f)
                        else scale.animateTo(1f, Motion.snappy(Motion.UnitThreshold))
                    }
                }
                var lastCount by remember { mutableIntStateOf(reaction.count) }
                LaunchedEffect(reaction.count, reaction.mine) {
                    if (reaction.count != lastCount) {
                        lastCount = reaction.count
                        if (!coroutineContext.isMotionReduced(context)) {
                            scale.snapTo(0.86f)
                            scale.animateTo(1f, Motion.snappy(Motion.UnitThreshold))
                        }
                    }
                }
                // Yours is tinted with the accent, as on the Mac.
                val fill = (if (reaction.mine) colors.accentTint else colors.reaction).compositeOver(colors.bubbleIn)
                Row(Modifier.height(UiMetrics.ChipHeight)
                    .graphicsLayer { scaleX = scale.value; scaleY = scale.value }
                    .background(fill, CircleShape)
                    // Your own bubble tints every chip alike, so there yours also wears an edge in the accent, white there.
                    .then(if (reaction.mine && colors.accentTint == colors.reaction) Modifier.border(UiMetrics.Divider, colors.accent, CircleShape)
                        else Modifier)
                    .semantics { selected = reaction.mine; contentDescription = chip(reaction, names, me) }
                    .combinedClickable(onLongClickLabel = "See who reacted", onLongClick = onShowWho) { onToggle?.invoke(reaction.key) }
                    .padding(horizontal = UiMetrics.GapSmall),
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny), verticalAlignment = Alignment.CenterVertically) {
                    Text(reaction.key, style = MaterialTheme.typography.bodyLarge)
                    Text("${reaction.count}", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Medium,
                        color = if (reaction.mine) colors.accent else colors.textPrimary)
                }
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

/** "🎉 100, You, Mira and 98 others": read for every chip, so it names at most three; the long press lists them all. */
private fun chip(reaction: MessageReaction, names: Map<String, String>, me: String?): String {
    val named = reaction.senders.sortedBy { it != me }.take(3).map { name(it, names, me) }
    val rest = reaction.count - named.size
    val who = if (named.isEmpty()) named else named + listOfNotNull(if (rest > 1) "$rest others" else if (rest == 1) "1 other" else null)
    return "${reaction.key} ${reaction.count}" + if (who.isEmpty()) "" else ", " + listed(who)
}

/** "Mira, You and sam": [ids] by the names the room knows them by, with you as "You". */
private fun who(ids: List<String>, names: Map<String, String>, me: String?): String = listed(ids.map { name(it, names, me) })

private fun name(id: String, names: Map<String, String>, me: String?) = if (id == me) "You" else names[id] ?: DisplayNames.localpart(id)

private fun listed(items: List<String>) =
    if (items.size > 1) items.dropLast(1).joinToString(", ") + " and " + items.last() else items.joinToString()
