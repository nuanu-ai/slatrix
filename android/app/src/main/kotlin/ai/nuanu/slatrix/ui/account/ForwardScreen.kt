package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationSearch
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import kotlinx.coroutines.launch

/**
 * Slack's Forward message page: pick a conversation by name, optionally add an accompanying message, review the
 * forwarded message preview card, and confirm with Forward. A refusal stays here to choose again.
 */
@Composable
fun ForwardScreen(
    message: ConversationMessage,
    from: RoomSummary,
    rooms: List<RoomSummary>,
    forward: suspend (RoomSummary, String) -> String?,
    onForwarded: (RoomSummary) -> Unit,
    onBack: () -> Unit,
) {
    val colors = SlatrixTheme.colors
    val scope = rememberCoroutineScope()
    var query by rememberSaveable { mutableStateOf("") }
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    var note by rememberSaveable { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var refusal by remember { mutableStateOf<String?>(null) }
    val selected = remember(rooms, selectedId) { rooms.firstOrNull { it.id == selectedId } }
    val shown = remember(rooms, query) { ConversationSearch.results(rooms, query) }
    LaunchedEffect(rooms, selectedId) {
        if (selectedId != null && rooms.none { it.id == selectedId }) selectedId = null
    }

    fun send() {
        val destination = selected ?: return
        if (sending) return
        sending = true
        refusal = null
        scope.launch {
            val failure = forward(destination, note)
            sending = false
            if (failure == null) onForwarded(destination) else refusal = failure
        }
    }

    PushedPage("Forward message", onBack) {
        item(key = "destination") {
            if (selected != null) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall)
                        .clip(MaterialTheme.shapes.large)
                        .background(colors.raised)
                        .border(UiMetrics.Hairline, colors.borderStrong, MaterialTheme.shapes.large)
                        .padding(start = UiMetrics.GapMedium, end = UiMetrics.GapTiny, top = UiMetrics.GapTiny, bottom = UiMetrics.GapTiny),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall),
                ) {
                    Box(Modifier.size(UiMetrics.CompactAvatar), contentAlignment = Alignment.Center) {
                        if (selected.direct) LiveAvatar(selected.initials, selected.colorIndex, UiMetrics.CompactAvatar, selected.avatarUrl)
                        else Icon(if (selected.isPrivate) SlackIcons.Lock else SlackIcons.Hash, null, Modifier.size(UiMetrics.Icon),
                            tint = colors.textSecondary)
                    }
                    Text(selected.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium,
                        color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Box(
                        Modifier.size(UiMetrics.Touch).clickable(enabled = !sending, role = Role.Button) {
                            selectedId = null
                            refusal = null
                        }.semantics { contentDescription = "Change destination" },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(SlackIcons.Close, null, Modifier.size(UiMetrics.Icon), tint = colors.textSecondary)
                    }
                }
            } else {
                SearchField(query, { query = it }, {}, Modifier, placeholder = "Add by name or channel")
            }
        }
        item(key = "note") {
            BasicTextField(
                value = note,
                onValueChange = { note = it },
                enabled = !sending,
                minLines = 2,
                maxLines = 5,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.textPrimary),
                cursorBrush = SolidColor(colors.accent),
                modifier = Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapTiny)
                    .semantics { contentDescription = "Optional message" },
                decorationBox = { field ->
                    Box(
                        Modifier.fillMaxWidth().heightIn(min = UiMetrics.ComposerMinHeight)
                            .clip(MaterialTheme.shapes.large)
                            .background(colors.raised)
                            .border(UiMetrics.Hairline, colors.border, MaterialTheme.shapes.large)
                            .padding(UiMetrics.GapMedium),
                    ) {
                        if (note.isEmpty()) {
                            Text("Add a message, if you’d like…", style = MaterialTheme.typography.bodyLarge,
                                color = colors.textSecondary)
                        }
                        field()
                    }
                },
            )
        }
        item(key = "preview") {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall)
                    .clip(MaterialTheme.shapes.large)
                    .background(colors.raised)
                    .border(UiMetrics.Hairline, colors.border, MaterialTheme.shapes.large)
                    .padding(UiMetrics.GapMedium)
                    .height(IntrinsicSize.Min),
                horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium),
            ) {
                Box(Modifier.width(UiMetrics.QuoteBar).fillMaxHeight().clip(CircleShape).background(colors.borderStrong))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                        LiveAvatar(message.initials, message.colorIndex, UiMetrics.CompactAvatar, message.avatarUrl)
                        Text(message.senderName, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(latestTime(message.timestamp), style = MaterialTheme.typography.labelSmall, color = colors.textSecondary)
                    }
                    Text(if (from.direct) from.name else "#${from.name}", style = MaterialTheme.typography.bodySmall,
                        color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(message.body, style = MaterialTheme.typography.bodyLarge, color = colors.textBody, maxLines = 4,
                        overflow = TextOverflow.Ellipsis)
                }
            }
        }
        refusal?.let { error ->
            item(key = "refusal") {
                Text(error, Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapTiny),
                    style = MaterialTheme.typography.bodyMedium, color = colors.destructive)
            }
        }
        if (selected != null) {
            item(key = "submit") {
                Button(
                    onClick = ::send,
                    enabled = !sending,
                    colors = ButtonDefaults.buttonColors(containerColor = colors.accentFill, contentColor = colors.onAccent),
                    modifier = Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall)
                        .heightIn(min = UiMetrics.Touch),
                ) {
                    Text("Forward", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
                }
            }
        } else {
            items(shown, key = { it.id }) { room ->
                Row(
                    Modifier.fillMaxWidth().heightIn(min = UiMetrics.ListRow)
                        .clickable(enabled = !sending, role = Role.Button) {
                            selectedId = room.id
                            refusal = null
                        }
                        .padding(horizontal = UiMetrics.GapLarge),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium),
                ) {
                    // As wide as an avatar, so every name lines up.
                    Box(Modifier.size(UiMetrics.CompactAvatar), contentAlignment = Alignment.Center) {
                        if (room.direct) LiveAvatar(room.initials, room.colorIndex, UiMetrics.CompactAvatar, room.avatarUrl)
                        else Icon(if (room.isPrivate) SlackIcons.Lock else SlackIcons.Hash, null, Modifier.size(UiMetrics.Icon),
                            tint = colors.textBody)
                    }
                    Text(room.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = colors.textPrimary,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}
