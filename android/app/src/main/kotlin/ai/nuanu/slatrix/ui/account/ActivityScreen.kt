package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ActivityItem
import ai.nuanu.slatrix.core.ActivityKind
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AlternateEmail
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow

private enum class ActivityFilter(val label: String) { All("All"), Dms("DMs"), Mentions("Mentions"), Threads("Threads") }

/** Slack's Activity tab: filter chips over what notified you, newest first. An item opens at its message. */
@Composable
fun ActivityScreen(items: List<ActivityItem>, onOpenItem: (ActivityItem) -> Unit, onOpenThread: (roomId: String, root: String) -> Unit,
    threads: @Composable (onOpenThread: (roomId: String, root: String) -> Unit) -> Unit = {}) {
    var filter by rememberSaveable { mutableStateOf(ActivityFilter.All) }
    var unreadOnly by rememberSaveable { mutableStateOf(false) }
    val shown = remember(items, filter, unreadOnly) {
        when (filter) {
            ActivityFilter.All -> items
            ActivityFilter.Threads -> emptyList()
            ActivityFilter.Dms -> items.filter { it.direct }
            ActivityFilter.Mentions -> items.filter { it.kind == ActivityKind.Mention }
        }.filter { !unreadOnly || it.unread }
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            .padding(start = UiMetrics.GapLarge, end = UiMetrics.GapLarge, bottom = UiMetrics.GapTiny),
            horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
            // Slack's Unreads narrows any filter to what you haven't opened, so it leads the row.
            ChoiceChip("Unreads", unreadOnly) { unreadOnly = !unreadOnly }
            ActivityFilter.entries.forEach { ChoiceChip(it.label, it == filter) { filter = it } }
        }
        // Threads lists the threads you're in, as Slack's Threads view does, rather than only the replies that notified you.
        if (filter == ActivityFilter.Threads) threads(onOpenThread)
        else LazyColumn(Modifier.fillMaxSize()) {
            if (shown.isEmpty()) item(key = "empty") {
                Box(Modifier.fillParentMaxSize().padding(UiMetrics.GapLarge), contentAlignment = Alignment.Center) {
                    Text(if (filter == ActivityFilter.All && !unreadOnly) "You’re all caught up" else "Nothing here yet",
                        style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textSecondary, textAlign = TextAlign.Center)
                }
            }
            items(shown, key = { it.id }) { item -> ActivityRow(item) { onOpenItem(item) } }
        }
    }
}

/** Material's filter chip: a light accent tint with a check when chosen, an outline when not. */
@Composable
internal fun ChoiceChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    FilterChip(selected, onClick, { Text(label, maxLines = 1) },
        leadingIcon = if (selected) {{ Icon(SlackIcons.Check, null, Modifier.size(FilterChipDefaults.IconSize)) }} else null,
        colors = FilterChipDefaults.filterChipColors(labelColor = colors.textPrimary, selectedContainerColor = colors.accentTint,
            selectedLabelColor = colors.accent, selectedLeadingIconColor = colors.accent),
        border = FilterChipDefaults.filterChipBorder(true, selected, borderColor = colors.borderStrong))
}

/** A DMs row for what notified you: the bold name and the accent dot mark what you haven't opened yet. */
@Composable
private fun ActivityRow(item: ActivityItem, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    val where = if (item.direct) "DM" else "#${item.roomName}"
    Row(Modifier.fillMaxWidth().semantics { if (item.unread) stateDescription = "Unread" }
        .clickable(role = Role.Button, onClick = onClick)
        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapMedium),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        Box {
            LiveAvatar(item.initials, item.colorIndex, UiMetrics.RowAvatar, item.avatarUrl)
            // Slack marks each item's avatar with what happened: the reaction, a mention, a thread or a DM.
            Box(Modifier.align(Alignment.BottomEnd).offset(x = UiMetrics.GapTiny, y = UiMetrics.GapTiny).size(UiMetrics.Icon)
                .drawBehind { drawCircle(colors.canvas, size.minDimension / 2 + UiMetrics.FaceRing.toPx()) },
                contentAlignment = Alignment.Center) {
                when {
                    item.kind == ActivityKind.Reaction -> Text(item.body, style = MaterialTheme.typography.labelSmall, maxLines = 1)
                    else -> Icon(when {
                        item.kind == ActivityKind.Mention -> Icons.Outlined.AlternateEmail
                        item.threadRoot != null -> Icons.Outlined.Forum
                        else -> Icons.Outlined.ChatBubbleOutline
                    }, null, Modifier.size(UiMetrics.Icon - UiMetrics.GapTiny), tint = colors.textPrimary)
                }
            }
        }
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                Text(item.senderName, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
                    fontWeight = if (item.unread) FontWeight.SemiBold else FontWeight.Normal, color = colors.textPrimary, maxLines = 1,
                    overflow = TextOverflow.Ellipsis)
                Text(latestTime(item.timestamp), style = MaterialTheme.typography.labelSmall, color = colors.textSecondary, maxLines = 1)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                Text(when {
                    item.kind == ActivityKind.Mention -> "Mentioned in $where"
                    item.kind == ActivityKind.Reaction -> "Reacted ${item.body} in $where"
                    item.threadRoot != null -> "Thread in $where"
                    item.direct -> "Direct Message"
                    else -> "Message in $where"
                }, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, maxLines = 1,
                    overflow = TextOverflow.Ellipsis)
                if (item.unread) Box(Modifier.size(UiMetrics.GapSmall).background(colors.accent, CircleShape))
            }
            // A reaction shows the message it reacted to, as Slack does.
            (if (item.kind == ActivityKind.Reaction) item.reactedTo else item.body)?.let {
                Text(it, style = MaterialTheme.typography.bodyMedium, color = colors.textPrimary, maxLines = 2,
                    overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
