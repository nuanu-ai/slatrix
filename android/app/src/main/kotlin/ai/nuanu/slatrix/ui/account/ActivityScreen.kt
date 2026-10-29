package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ActivityItem
import ai.nuanu.slatrix.core.ActivityKind
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow

private enum class ActivityFilter(val label: String) { All("All"), Dms("DMs"), Mentions("Mentions"), Threads("Threads") }

/** Slack's Activity tab: filter chips over what notified you, newest first. An item opens at its message. */
@Composable
fun ActivityScreen(items: List<ActivityItem>, onOpenItem: (ActivityItem) -> Unit, onOpenThread: (roomId: String, root: String) -> Unit,
    threads: @Composable (onOpenThread: (roomId: String, root: String) -> Unit) -> Unit = {}) {
    var filter by rememberSaveable { mutableStateOf(ActivityFilter.All) }
    val shown = remember(items, filter) {
        when (filter) {
            ActivityFilter.All -> items
            ActivityFilter.Threads -> emptyList()
            ActivityFilter.Dms -> items.filter { it.direct }
            ActivityFilter.Mentions -> items.filter { it.kind == ActivityKind.Mention }
        }
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapLarge),
            horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
            ActivityFilter.entries.forEach { ActivityChip(it.label, it == filter) { filter = it } }
        }
        // Threads lists the threads you're in, as Slack's Threads view does, rather than only the replies that notified you.
        if (filter == ActivityFilter.Threads) threads(onOpenThread)
        else LazyColumn(Modifier.fillMaxSize()) {
            if (shown.isEmpty()) item(key = "empty") {
                Text(if (filter == ActivityFilter.All) "You’re all caught up" else "Nothing here yet", Modifier.padding(UiMetrics.GapLarge),
                    style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textSecondary)
            }
            items(shown, key = { it.id }) { item ->
                HorizontalDivider(color = SlatrixTheme.colors.border)
                ActivityRow(item) { onOpenItem(item) }
            }
        }
    }
}

@Composable
private fun ActivityChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    Surface(onClick = onClick, Modifier.semantics { this.selected = selected }, shape = MaterialTheme.shapes.medium,
        color = if (selected) colors.textPrimary else colors.canvas, contentColor = if (selected) colors.canvas else colors.textPrimary,
        border = if (selected) null else BorderStroke(UiMetrics.Divider, colors.border)) {
        Box(Modifier.heightIn(min = UiMetrics.Touch - UiMetrics.GapSmall).padding(horizontal = UiMetrics.GapLarge),
            contentAlignment = Alignment.Center) {
            Text(label, style = MaterialTheme.typography.bodyLarge, fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal)
        }
    }
}

@Composable
private fun ActivityRow(item: ActivityItem, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    val where = if (item.direct) "DM" else "#${item.roomName}"
    Row(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onClick).padding(UiMetrics.GapLarge),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
        Box(Modifier.padding(top = UiMetrics.GapTiny)) {
            LiveAvatar(item.initials, item.colorIndex)
            // Slack marks each item's avatar with what happened: the reaction, a mention, a thread or a DM.
            Box(Modifier.align(Alignment.BottomEnd).offset(x = UiMetrics.GapTiny, y = UiMetrics.GapTiny).size(UiMetrics.Icon)
                .background(colors.canvas, CircleShape), contentAlignment = Alignment.Center) {
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
        Column(Modifier.weight(1f).padding(start = UiMetrics.GapTiny)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                Text(item.senderName, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold,
                    color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(latestTime(item.timestamp), style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary)
            }
            Text(when {
                item.kind == ActivityKind.Mention -> "Mentioned in $where"
                item.kind == ActivityKind.Reaction -> "Reacted in $where"
                item.threadRoot != null -> "Thread in $where"
                item.direct -> "Direct Message"
                else -> "Message in $where"
            }, style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (item.kind != ActivityKind.Reaction) Text(item.body, Modifier.padding(top = UiMetrics.GapTiny),
                style = MaterialTheme.typography.bodyLarge, color = colors.textBody, maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
    }
}
