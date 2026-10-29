package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SavedMessage
import ai.nuanu.slatrix.core.SavedPreview
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow

/** Slack's Later: what you saved, newest first, each read from its conversation; a tap opens it where it is. */
@Composable
fun LaterScreen(saved: List<SavedMessage>, rooms: List<RoomSummary>, load: suspend (SavedMessage) -> SavedPreview?,
    onOpen: (SavedMessage) -> Unit, onRemove: (SavedMessage) -> Unit, onBack: () -> Unit) {
    PushedPage("Later", onBack) {
        if (saved.isEmpty()) item {
            Text("Nothing saved for later", Modifier.padding(UiMetrics.GapLarge), style = MaterialTheme.typography.bodyLarge,
                color = SlatrixTheme.colors.textSecondary)
        }
        items(saved, key = { it.roomId + it.eventId }) { item ->
            SavedCard(item, rooms.firstOrNull { it.id == item.roomId }, load, { onOpen(item) }) { onRemove(item) }
        }
    }
}

@Composable
private fun SavedCard(saved: SavedMessage, room: RoomSummary?, load: suspend (SavedMessage) -> SavedPreview?, onOpen: () -> Unit,
    onRemove: () -> Unit) {
    val colors = SlatrixTheme.colors
    var preview by remember(saved) { mutableStateOf<SavedPreview?>(null) }
    var loaded by remember(saved) { mutableStateOf(false) }
    LaunchedEffect(saved) {
        preview = load(saved)
        loaded = true
    }
    Column(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen)
        .padding(start = UiMetrics.GapLarge, bottom = UiMetrics.GapMedium)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(when {
                room == null -> "Conversation unavailable"
                room.direct -> room.name
                else -> "#${room.name}"
            }, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Bold,
                color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            IconButton(onClick = onRemove) { Icon(SlackIcons.BookmarkFilled, "Remove from Later", Modifier.size(UiMetrics.Icon)) }
        }
        val shown = preview
        Row(Modifier.padding(end = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall),
            verticalAlignment = Alignment.CenterVertically) {
            // The line keeps its height while the message loads, so the card never grows under the reader.
            Text(shown?.senderName ?: "", Modifier.weight(1f, fill = false), style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (shown != null) Text("${dayLabel(shown.timestamp)} at ${timeLabel(shown.timestamp)}", style = MaterialTheme.typography.bodySmall,
                color = colors.textSecondary, maxLines = 1)
        }
        Text(when {
            shown != null -> shown.body
            loaded -> "This message is unavailable."
            else -> ""
        }, Modifier.padding(end = UiMetrics.GapLarge), style = MaterialTheme.typography.bodyLarge,
            color = if (shown != null) colors.textBody else colors.textSecondary, minLines = 1, maxLines = 4, overflow = TextOverflow.Ellipsis)
    }
}

/** Slack's Later card at the top of Home: how many messages wait there. */
@Composable
internal fun LaterCard(count: Int, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    Surface(Modifier.width(UiMetrics.HomeCard).clickable(role = Role.Button, onClick = onClick), shape = MaterialTheme.shapes.large,
        color = colors.canvas, border = BorderStroke(UiMetrics.Divider, colors.border)) {
        Column(Modifier.padding(UiMetrics.GapMedium), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
            Icon(SlackIcons.Bookmark, null, Modifier.size(UiMetrics.LargeIcon), tint = colors.textPrimary)
            Text("Later", style = MaterialTheme.typography.bodyLarge, color = colors.textPrimary, maxLines = 1)
            Text(if (count == 1) "1 item" else "$count items", style = MaterialTheme.typography.bodyMedium,
                color = colors.textSecondary, maxLines = 1)
        }
    }
}
