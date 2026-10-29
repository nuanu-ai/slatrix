package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ThreadFeedItem
import ai.nuanu.slatrix.core.ThreadFeedMessage
import ai.nuanu.slatrix.core.ThreadFeedState
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import kotlinx.coroutines.delay

/** The threads you're in, newest activity first; one with replies you haven't read is bold and dotted. */
@Composable
fun ThreadsFeed(state: ThreadFeedState, onOpenThread: (roomId: String, root: String) -> Unit) {
    val colors = SlatrixTheme.colors
    var waited by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { delay(UiMetrics.ProgressDelayMillis); waited = true }
    LazyColumn(Modifier.fillMaxSize()) {
        if (state.items.isEmpty()) item(key = "empty") {
            Box(Modifier.fillMaxWidth().height(UiMetrics.Touch), contentAlignment = Alignment.Center) {
                if (!state.loading) Text("No threads yet", style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary)
                else if (waited) CircularProgressIndicator(Modifier.size(UiMetrics.Icon))
            }
        }
        items(state.items, key = { it.roomId + " " + it.rootId }) { thread ->
            HorizontalDivider(color = colors.border)
            ThreadRow(thread) { onOpenThread(thread.roomId, thread.rootId) }
        }
    }
}

@Composable
private fun ThreadRow(thread: ThreadFeedItem, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    Column(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onClick)
        .semantics { if (thread.unread) stateDescription = "Unread replies" }.padding(UiMetrics.GapLarge),
        verticalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
            Text(if (thread.direct) thread.roomName else "#${thread.roomName}", Modifier.weight(1f, fill = false),
                style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold,
                color = if (thread.unread) colors.textPrimary else colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (thread.unread) Box(Modifier.size(UiMetrics.GapSmall).background(colors.mention, CircleShape))
        }
        ThreadMessage(thread.root, UiMetrics.Avatar, 3)
        thread.latest?.let {
            Box(Modifier.padding(start = UiMetrics.Avatar + UiMetrics.GapSmall)) { ThreadMessage(it, UiMetrics.CompactAvatar, 2) }
        }
        Text(if (thread.replies == 1) "1 reply" else "${thread.replies} replies",
            Modifier.padding(start = UiMetrics.Avatar + UiMetrics.GapSmall), style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.Bold, color = colors.accent)
    }
}

@Composable
private fun ThreadMessage(message: ThreadFeedMessage, avatar: Dp, lines: Int) {
    val colors = SlatrixTheme.colors
    Row(horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
        LiveAvatar(message.initials, message.colorIndex, avatar)
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                Text(message.senderName, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(latestTime(message.timestamp), style = MaterialTheme.typography.bodySmall, color = colors.textSecondary, maxLines = 1)
            }
            Text(message.body, style = MaterialTheme.typography.bodyLarge, color = colors.textBody, maxLines = lines,
                overflow = TextOverflow.Ellipsis)
        }
    }
}
