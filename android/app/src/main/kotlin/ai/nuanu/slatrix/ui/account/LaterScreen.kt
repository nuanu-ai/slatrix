package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SavedMessage
import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.SavedPreview
import ai.nuanu.slatrix.ui.designsystem.Motion
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitHorizontalTouchSlopOrCancellation
import androidx.compose.foundation.gestures.horizontalDrag
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import kotlinx.coroutines.launch
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
    val haptics = LocalHapticFeedback.current
    // A swipe left removes the card, as Slack's Later does: the card follows the finger and the bookmark fades in behind
    // it. Only a leftward start is the card's; a rightward one stays with the tabs, so DMs is still a swipe away.
    val drag = remember { Animatable(0f) }
    val reach = with(LocalDensity.current) { UiMetrics.Swipe.toPx() }
    val swipes = rememberCoroutineScope()
    Box(Modifier.fillMaxWidth().pointerInput(saved) {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            awaitHorizontalTouchSlopOrCancellation(down.id) { change, over -> if (over < 0) change.consume() }
                ?: return@awaitEachGesture
            var past = false
            horizontalDrag(down.id) { change ->
                val next = (drag.value + change.positionChange().x * if (drag.value < -reach) 0.3f else 1f).coerceIn(-reach * 1.5f, 0f)
                change.consume()
                swipes.launch { drag.snapTo(next) }
                if (next <= -reach && !past) haptics.performHapticFeedback(HapticFeedbackType.GestureThresholdActivate)
                past = next <= -reach
            }
            swipes.launch {
                if (past) {
                    drag.animateTo(-size.width.toFloat(), Motion.pane())
                    onRemove()
                }
                drag.snapTo(0f)
            }
        }
    }) {
    Icon(SlackIcons.Bookmark, null, Modifier.align(Alignment.CenterEnd).padding(end = UiMetrics.GapLarge).size(UiMetrics.Icon)
        .graphicsLayer {
            val shown = (-drag.value / reach).coerceIn(0f, 1f)
            alpha = shown
            scaleX = 0.6f + 0.4f * shown
            scaleY = scaleX
        }, tint = colors.textSecondary)
    Row(Modifier.fillMaxWidth().graphicsLayer { translationX = drag.value }.background(colors.canvas)
        .clickable(role = Role.Button, onClick = onOpen)
        .padding(start = UiMetrics.GapLarge, top = UiMetrics.GapMedium, bottom = UiMetrics.GapMedium),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        // The picture's place is kept while the message loads, so the text never shifts when it lands.
        Box(Modifier.padding(top = UiMetrics.GapTiny).size(UiMetrics.Avatar)) {
            preview?.let { LiveAvatar(AvatarPlaceholder.initials(it.senderName), AvatarPlaceholder.colorIndex(it.senderId), url = it.avatarUrl) }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(UiMetrics.Hairline * 4)) {
            Text(when {
                room == null -> "Conversation unavailable"
                room.direct -> "Direct message"
                else -> "#${room.name}"
            }, style = MaterialTheme.typography.labelMedium, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val shown = preview
            Row(horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
                // The line keeps its height while the message loads, so the row never grows under the reader. The name
                // takes what it needs and the time gives way.
                Text(shown?.senderName ?: "", style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Medium, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (shown != null) Text("${dayLabel(shown.timestamp)} at ${timeLabel(shown.timestamp)}", Modifier.weight(1f, fill = false),
                    style = MaterialTheme.typography.bodySmall, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Text(when {
                shown != null -> shown.body
                loaded -> "This message is unavailable."
                else -> ""
            }, style = MaterialTheme.typography.bodyMedium,
                color = if (shown != null) colors.textBody else colors.textSecondary, minLines = 1, maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
        IconButton(onClick = onRemove) {
            Icon(SlackIcons.BookmarkFilled, "Remove from Later", Modifier.size(UiMetrics.Icon), tint = colors.textSecondary)
        }
    }
    }
}
