package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SavedMessage
import ai.nuanu.slatrix.core.SavedPreview
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow

/** Slack's Later: what you saved, newest first, each read from its conversation; a tap opens it where it is. */
@Composable
fun LaterScreen(saved: List<SavedMessage>, rooms: List<RoomSummary>, load: suspend (SavedMessage) -> SavedPreview?,
    onOpen: (SavedMessage) -> Unit, onRemove: (SavedMessage) -> Unit,
    // Read once per message, so coming back to a card shows it at once; the caller keeps them across tab switches.
    // Kept by message, so a save time merged from another device doesn't read a card again.
    previews: MutableMap<Pair<String, String>, SavedPreview?> = remember { mutableStateMapOf() },
    list: LazyListState = rememberLazyListState()) {
    val newestFirst = remember(saved) { saved.sortedByDescending { it.savedAt } }
    LazyColumn(Modifier.fillMaxSize(), list, contentPadding = PaddingValues(top = UiMetrics.GapSmall)) {
        if (saved.isEmpty()) item {
            Text("Nothing saved for later", Modifier.padding(UiMetrics.GapLarge), style = MaterialTheme.typography.bodyLarge,
                color = SlatrixTheme.colors.textSecondary)
        }
        // The room's length first, as the Mac's ID does, so two different pairs never make the same key.
        items(newestFirst, key = { "${it.roomId.length}:${it.roomId}${it.eventId}" }) { item ->
            SavedCard(item, rooms.firstOrNull { it.id == item.roomId }, previews, load, { onOpen(item) }) { onRemove(item) }
        }
    }
}

@Composable
private fun SavedCard(saved: SavedMessage, room: RoomSummary?, previews: MutableMap<Pair<String, String>, SavedPreview?>,
    load: suspend (SavedMessage) -> SavedPreview?, onOpen: () -> Unit, onRemove: () -> Unit) {
    val colors = SlatrixTheme.colors
    val key = saved.roomId to saved.eventId
    LaunchedEffect(key) { if (key !in previews) previews[key] = load(saved) }
    val loaded = key in previews
    val preview = previews[key]
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
