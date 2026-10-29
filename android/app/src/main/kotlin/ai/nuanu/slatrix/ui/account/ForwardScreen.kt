package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import kotlinx.coroutines.launch

/**
 * Slack's Forward message page: the message, then the conversations to send it to, found by name. A pick [forward]s
 * it, which answers why it can't go or null once it went; a refusal stays here to choose again.
 */
@Composable
fun ForwardScreen(message: ConversationMessage, from: RoomSummary, rooms: List<RoomSummary>, forward: suspend (RoomSummary) -> String?,
    onForwarded: (RoomSummary) -> Unit, onBack: () -> Unit) {
    val colors = SlatrixTheme.colors
    val scope = rememberCoroutineScope()
    var query by rememberSaveable { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var refusal by remember { mutableStateOf<String?>(null) }
    fun pick(room: RoomSummary) {
        // One copy per pick, as the Mac's busy guard keeps it.
        if (sending) return
        sending = true
        refusal = null
        scope.launch {
            val failure = forward(room)
            sending = false
            if (failure == null) onForwarded(room) else refusal = failure
        }
    }
    val shown = remember(rooms, query) { rooms.filter { it.name.contains(query.trim(), ignoreCase = true) } }
    PushedPage("Forward message", onBack) {
        item {
            Column(Modifier.fillMaxWidth().padding(UiMetrics.GapLarge).background(colors.raised, MaterialTheme.shapes.large)
                .padding(UiMetrics.GapMedium), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
                Text(if (from.direct) "From ${from.name}" else "From #${from.name}", style = MaterialTheme.typography.bodySmall,
                    color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(message.senderName, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold,
                    color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(message.body, style = MaterialTheme.typography.bodyLarge, color = colors.textBody, maxLines = 4,
                    overflow = TextOverflow.Ellipsis)
            }
        }
        refusal?.let { item { Text(it, Modifier.padding(horizontal = UiMetrics.GapLarge), style = MaterialTheme.typography.bodyMedium,
            color = colors.destructive) } }
        item { SearchField(query, { query = it }, {}, Modifier) }
        items(shown, key = { it.id }) { room ->
            Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.ListRow).clickable(role = Role.Button) { pick(room) }
                .padding(horizontal = UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
                // As wide as an avatar, so every name lines up.
                Box(Modifier.size(UiMetrics.CompactAvatar), contentAlignment = Alignment.Center) {
                    if (room.direct) LiveAvatar(room.initials, room.colorIndex, UiMetrics.CompactAvatar)
                    else Icon(if (room.isPrivate) SlackIcons.Lock else SlackIcons.Hash, null, Modifier.size(UiMetrics.Icon),
                        tint = colors.textBody)
                }
                Text(room.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = colors.textPrimary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
