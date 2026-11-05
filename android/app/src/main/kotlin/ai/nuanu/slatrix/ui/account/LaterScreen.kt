package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.LaterState
import ai.nuanu.slatrix.core.ReminderPreset
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SavedList
import ai.nuanu.slatrix.core.SavedMessage
import ai.nuanu.slatrix.core.SavedPreview
import ai.nuanu.slatrix.ui.designsystem.BottomSheet
import ai.nuanu.slatrix.ui.designsystem.MenuItem
import ai.nuanu.slatrix.ui.designsystem.Motion
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import android.text.format.DateUtils
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitHorizontalTouchSlopOrCancellation
import androidx.compose.foundation.gestures.horizontalDrag
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SecondaryTabRow
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** What Later can do with an item, so the screen takes plain callbacks rather than the service. */
class LaterActions(val open: (SavedMessage) -> Unit, val move: (SavedMessage, LaterState) -> Unit = { _, _ -> },
    val remind: (SavedMessage, Long?) -> Unit = { _, _ -> }, val remove: (SavedMessage) -> Unit = {})

/** A move or removal waiting out its Undo; null [to] removes. */
private data class Pending(val item: SavedMessage, val to: LaterState?)

/**
 * Slack's Later: In progress, Archived and Completed, each a list of messages read from their conversations; a tap
 * opens one where it is, a swipe left marks one in progress complete, and a long press offers the rest.
 */
@Composable
fun LaterScreen(saved: SavedList, rooms: List<RoomSummary>, load: suspend (SavedMessage) -> SavedPreview?, actions: LaterActions,
    // Read once per message, so coming back to a card shows it at once; the caller keeps them across tab switches.
    // Kept by message, so a save time merged from another device doesn't read a card again.
    previews: MutableMap<Pair<String, String>, SavedPreview?> = remember { mutableStateMapOf() },
    list: LazyListState = rememberLazyListState(), now: () -> Long = System::currentTimeMillis) {
    var tab by rememberSaveable { mutableStateOf(LaterState.IN_PROGRESS) }
    // A card moved or removed leaves at once but changes only once its Undo has gone, so Undo puts it back as it was.
    var pending by remember { mutableStateOf<Pending?>(null) }
    var sheet by remember { mutableStateOf<SavedMessage?>(null) }
    var reminding by remember { mutableStateOf<SavedMessage?>(null) }
    var custom by remember { mutableStateOf<SavedMessage?>(null) }
    val current by rememberUpdatedState(actions)
    val commit = { change: Pending -> change.to?.let { current.move(change.item, it) } ?: current.remove(change.item) }
    pending?.let { change -> LaunchedEffect(change) { delay(UiMetrics.NoticeMillis); commit(change); pending = null } }
    DisposableEffect(Unit) { onDispose { pending?.let(commit) } }
    val act = { item: SavedMessage, to: LaterState? -> pending?.let(commit); pending = Pending(item, to) }
    // Due labels move on with the clock.
    var clock by remember { mutableLongStateOf(now()) }
    LaunchedEffect(Unit) { while (true) { delay(DateUtils.MINUTE_IN_MILLIS); clock = now() } }
    val shown = remember(saved, pending, tab) { saved.tab(tab).filter { it != pending?.item } }
    val otherTab = remember(tab) { LazyListState() }
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            SecondaryTabRow(LaterState.entries.indexOf(tab), containerColor = SlatrixTheme.colors.canvas,
                contentColor = SlatrixTheme.colors.textPrimary) {
                LaterState.entries.forEach { state ->
                    // Without the text slot's inset, so "In progress" fits a third of a narrow phone at a large font.
                    Tab(state == tab, { tab = state }, Modifier.heightIn(min = UiMetrics.Touch),
                        selectedContentColor = SlatrixTheme.colors.textPrimary, unselectedContentColor = SlatrixTheme.colors.textSecondary) {
                        Text(state.title, Modifier.padding(horizontal = UiMetrics.GapTiny), style = MaterialTheme.typography.titleSmall,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            LazyColumn(Modifier.fillMaxSize(), if (tab == LaterState.IN_PROGRESS) list else otherTab,
                contentPadding = PaddingValues(top = UiMetrics.GapSmall)) {
                if (shown.isEmpty()) item {
                    Text(when (tab) {
                        LaterState.IN_PROGRESS -> "Nothing saved for later"
                        LaterState.ARCHIVED -> "Nothing archived"
                        LaterState.COMPLETED -> "Nothing completed yet"
                    }, Modifier.padding(UiMetrics.GapLarge), style = MaterialTheme.typography.bodyLarge,
                        color = SlatrixTheme.colors.textSecondary)
                }
                // The room's length first, as the Mac's ID does, so two different pairs never make the same key.
                items(shown, key = { "${it.roomId.length}:${it.roomId}${it.eventId}" }) { item ->
                    val primary = when (item.state) {
                        LaterState.IN_PROGRESS -> Triple(SlackIcons.Check, "Mark complete", LaterState.COMPLETED)
                        LaterState.ARCHIVED -> Triple(SlackIcons.Undo, "Move to In progress", LaterState.IN_PROGRESS)
                        LaterState.COMPLETED -> Triple(SlackIcons.Undo, "Mark incomplete", LaterState.IN_PROGRESS)
                    }
                    SavedCard(item, rooms.firstOrNull { it.id == item.roomId }, previews, load, clock, primary.first, primary.second,
                        swipes = item.state == LaterState.IN_PROGRESS, onOpen = { actions.open(item) },
                        onPrimary = { act(item, primary.third) }, onMore = { sheet = item })
                }
            }
        }
        pending?.let { change ->
            Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge).semantics { liveRegion = LiveRegionMode.Polite },
                action = { TextButton(onClick = { pending = null }) { Text("Undo") } }) {
                Text(when (change.to) {
                    LaterState.COMPLETED -> "Marked as complete"
                    LaterState.ARCHIVED -> "Archived"
                    LaterState.IN_PROGRESS -> "Moved to In progress"
                    null -> "Removed from Later"
                })
            }
        }
    }
    sheet?.let { item ->
        LaterSheet(item, { sheet = null }, { to -> sheet = null; act(item, to) }, { sheet = null; reminding = item })
    }
    reminding?.let { item ->
        ReminderSheet(item, now, { reminding = null }, { at -> reminding = null; actions.remind(item, at) },
            { reminding = null; custom = item })
    }
    custom?.let { item -> CustomReminder(item.remindAt ?: ReminderPreset.IN_1_HOUR.at(now()), now, { custom = null }) { at ->
        custom = null
        actions.remind(item, at)
    } }
}

/** Slack's tap-and-hold actions for something in Later; [move] with null removes it. */
@Composable
private fun LaterSheet(item: SavedMessage, onDismiss: () -> Unit, move: (LaterState?) -> Unit, onRemind: () -> Unit) {
    BottomSheet(onDismiss, SlatrixTheme.colors.overlay) {
        when (item.state) {
            LaterState.IN_PROGRESS -> {
                MenuItem(SlackIcons.Check, "Mark complete") { move(LaterState.COMPLETED) }
                MenuItem(SlackIcons.Clock, if (item.remindAt == null) "Remind me" else "Edit reminder", onClick = onRemind)
                MenuItem(SlackIcons.Archive, "Archive") { move(LaterState.ARCHIVED) }
            }
            LaterState.ARCHIVED -> MenuItem(SlackIcons.Undo, "Move to In progress") { move(LaterState.IN_PROGRESS) }
            LaterState.COMPLETED -> MenuItem(SlackIcons.Undo, "Mark incomplete") { move(LaterState.IN_PROGRESS) }
        }
        MenuItem(SlackIcons.Trash, "Remove from Later", SlatrixTheme.colors.destructive) { move(null) }
    }
}

/** Remind me's choices, each with when it lands, then Custom and, with a reminder set, Clear reminder. */
@Composable
private fun ReminderSheet(item: SavedMessage, now: () -> Long, onDismiss: () -> Unit, onPick: (Long?) -> Unit, onCustom: () -> Unit) {
    val from = remember { now() }
    BottomSheet(onDismiss, SlatrixTheme.colors.overlay) {
        ReminderPreset.entries.forEach { preset ->
            val at = preset.at(from)
            val day = if (preset == ReminderPreset.NEXT_WEEK) "${dayLabelAhead(at, from)} " else ""
            MenuItem(SlackIcons.Clock, "${preset.title} · $day${timeLabel(at)}") { onPick(at) }
        }
        MenuItem(SlackIcons.Clock, "Custom…", onClick = onCustom)
        if (item.remindAt != null) MenuItem(SlackIcons.Close, "Clear reminder") { onPick(null) }
    }
}

/** A day, then a time, no earlier than now, as Material's pickers ask for them. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CustomReminder(start: Long, now: () -> Long, onDismiss: () -> Unit, onSave: (Long) -> Unit) {
    val zone = ZoneId.systemDefault()
    var day by remember { mutableStateOf<LocalDate?>(null) }
    val today = remember { Instant.ofEpochMilli(now()).atZone(zone).toLocalDate() }
    val chosen = day
    if (chosen == null) {
        val startDay = Instant.ofEpochMilli(start).atZone(zone).toLocalDate()
        val state = rememberDatePickerState(startDay.atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli(),
            selectableDates = object : SelectableDates {
                // The picker hands days as UTC midnights.
                override fun isSelectableDate(utcTimeMillis: Long) =
                    !Instant.ofEpochMilli(utcTimeMillis).atZone(ZoneOffset.UTC).toLocalDate().isBefore(today)
            })
        DatePickerDialog(onDismiss, confirmButton = {
            TextButton({ state.selectedDateMillis?.let { day = Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate() } },
                enabled = state.selectedDateMillis != null) { Text("Next") }
        }, dismissButton = { TextButton(onDismiss) { Text("Cancel") } }) { DatePicker(state) }
    } else {
        val startTime = Instant.ofEpochMilli(start).atZone(zone).toLocalTime()
        val time = rememberTimePickerState(startTime.hour, startTime.minute)
        val at = chosen.atTime(LocalTime.of(time.hour, time.minute)).atZone(zone).toInstant().toEpochMilli()
        AlertDialog(onDismiss, confirmButton = { TextButton({ onSave(at) }, enabled = at > now()) { Text("Save") } },
            dismissButton = { TextButton(onDismiss) { Text("Cancel") } }, text = { TimePicker(time) })
    }
}

/** When a reminder is due, as Slack says it: soon as minutes or hours, later as a day and time; past it, overdue. */
private fun dueLabel(at: Long, now: Long): String = when {
    at <= now -> "Overdue"
    at - now < DateUtils.DAY_IN_MILLIS ->
        "Due ${DateUtils.getRelativeTimeSpanString(at, now, DateUtils.MINUTE_IN_MILLIS).toString().replaceFirstChar { it.lowercase() }}"
    else -> "Due ${dayLabelAhead(at, now)} at ${timeLabel(at)}"
}

/** Tomorrow, then the weekday within a week, then the date. */
private fun dayLabelAhead(at: Long, now: Long): String {
    val zone = ZoneId.systemDefault()
    val day = Instant.ofEpochMilli(at).atZone(zone).toLocalDate()
    val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
    return when {
        day == today -> "Today"
        day == today.plusDays(1) -> "Tomorrow"
        day.isBefore(today.plusDays(7)) -> DateUtils.formatDateTime(null, at, DateUtils.FORMAT_SHOW_WEEKDAY or DateUtils.FORMAT_ABBREV_WEEKDAY)
        else -> DateUtils.formatDateTime(null, at, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH or DateUtils.FORMAT_NO_YEAR)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SavedCard(saved: SavedMessage, room: RoomSummary?, previews: MutableMap<Pair<String, String>, SavedPreview?>,
    load: suspend (SavedMessage) -> SavedPreview?, now: Long, primaryIcon: ImageVector,
    primaryLabel: String, swipes: Boolean, onOpen: () -> Unit, onPrimary: () -> Unit, onMore: () -> Unit) {
    val colors = SlatrixTheme.colors
    val key = saved.roomId to saved.eventId
    LaunchedEffect(key) { if (key !in previews) previews[key] = load(saved) }
    val loaded = key in previews
    val preview = previews[key]
    val haptics = LocalHapticFeedback.current
    // A swipe left marks the card complete, as Slack's Later does: the card follows the finger and the check fades in
    // behind it.
    val drag = remember { Animatable(0f) }
    val reach = with(LocalDensity.current) { UiMetrics.Swipe.toPx() }
    val swipeScope = rememberCoroutineScope()
    Box(Modifier.fillMaxWidth().then(if (!swipes) Modifier else Modifier.pointerInput(saved) {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            awaitHorizontalTouchSlopOrCancellation(down.id) { change, over -> if (over < 0) change.consume() }
                ?: return@awaitEachGesture
            var past = false
            horizontalDrag(down.id) { change ->
                val next = (drag.value + change.positionChange().x * if (drag.value < -reach) 0.3f else 1f).coerceIn(-reach * 1.5f, 0f)
                change.consume()
                swipeScope.launch { drag.snapTo(next) }
                if (next <= -reach && !past) haptics.performHapticFeedback(HapticFeedbackType.GestureThresholdActivate)
                past = next <= -reach
            }
            swipeScope.launch {
                if (past) {
                    drag.animateTo(-size.width.toFloat(), Motion.pane())
                    onPrimary()
                }
                drag.snapTo(0f)
            }
        }
    })) {
    if (swipes) Icon(SlackIcons.Check, null, Modifier.align(Alignment.CenterEnd).padding(end = UiMetrics.GapLarge).size(UiMetrics.Icon)
        .graphicsLayer {
            val shown = (-drag.value / reach).coerceIn(0f, 1f)
            alpha = shown
            scaleX = 0.6f + 0.4f * shown
            scaleY = scaleX
        }, tint = colors.textSecondary)
    Row(Modifier.fillMaxWidth().graphicsLayer { translationX = drag.value }.background(colors.canvas)
        .combinedClickable(role = Role.Button, onLongClickLabel = "More actions", onLongClick = {
            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            onMore()
        }, onClick = onOpen)
        .semantics { customActions = listOf(CustomAccessibilityAction("More actions") { onMore(); true }) }
        .padding(start = UiMetrics.GapLarge, top = UiMetrics.GapMedium, bottom = UiMetrics.GapMedium),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        // The picture's place is kept while the message loads, so the text never shifts when it lands.
        Box(Modifier.padding(top = UiMetrics.GapTiny).size(UiMetrics.Avatar)) {
            preview?.let { LiveAvatar(AvatarPlaceholder.initials(it.senderName), AvatarPlaceholder.colorIndex(it.senderId), url = it.avatarUrl) }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(UiMetrics.Hairline * 4)) {
            // The reminder shares the conversation's line, so setting one never changes the card's height.
            Row(horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
                Text(when {
                    room == null -> "Conversation unavailable"
                    room.direct -> "Direct message"
                    else -> "#${room.name}"
                }, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.labelMedium, color = colors.textSecondary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                saved.remindAt?.let { at ->
                    Text(dueLabel(at, now), style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        color = if (at <= now) colors.destructive else colors.textSecondary)
                }
            }
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
        IconButton(onClick = onPrimary) {
            Icon(primaryIcon, primaryLabel, Modifier.size(UiMetrics.Icon), tint = colors.textSecondary)
        }
    }
    }
}
