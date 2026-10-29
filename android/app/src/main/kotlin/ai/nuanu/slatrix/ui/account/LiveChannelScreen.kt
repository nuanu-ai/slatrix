package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.DayDivider
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.ui.designsystem.AvatarStyle
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import android.content.ClipData
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Date
import java.util.Locale

@Composable
fun LiveChannelScreen(room: RoomSummary, state: ConversationState, composer: ComposerState,
    onDraft: (String) -> Unit, onSend: () -> Unit, onBack: () -> Unit, onLoadOlder: () -> Unit, onRead: (String) -> Unit,
    onRetry: () -> Unit, onRetrySend: (ConversationMessage) -> Unit = {}, onDeleteUnsent: (ConversationMessage) -> Unit = {}) {
    val colors = SlatrixTheme.colors
    val list = rememberLazyListState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var resumed by remember(lifecycle) { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, _ -> resumed = lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    val latest = state.rows.lastOrNull { it is ConversationMessage && it.eventId != null } as ConversationMessage?
    val read by rememberUpdatedState(onRead)
    LaunchedEffect(latest?.id, latest?.eventId, resumed) {
        val event = latest?.eventId ?: return@LaunchedEffect
        if (!resumed) return@LaunchedEffect
        snapshotFlow {
            list.layoutInfo.visibleItemsInfo.any { item ->
                item.key == latest.id && item.offset + item.size <= list.layoutInfo.viewportEndOffset &&
                    item.offset + item.size > list.layoutInfo.viewportStartOffset
            }
        }.distinctUntilChanged().collect { visible -> if (visible) read(event) }
    }
    val newest = state.rows.lastOrNull() as? ConversationMessage
    var following by remember { mutableStateOf(true) }
    LaunchedEffect(list) {
        snapshotFlow { list.isScrollInProgress }.collect { scrolling ->
            following = !scrolling && list.firstVisibleItemIndex == 0 && list.firstVisibleItemScrollOffset == 0
        }
    }
    LaunchedEffect(newest?.id) {
        if (following || newest?.own == true && newest.sendState == MessageSendState.Sending) list.scrollToItem(0)
    }
    val loadOlder by rememberUpdatedState(onLoadOlder)
    // Asks again after every page while the top stays near, so pages of hidden events don't stall it.
    LaunchedEffect(list, !state.loading && state.hasMore && !state.loadingHistory) {
        // Waits for the cached messages, so a conversation that has plenty doesn't page on open.
        if (state.loading || !state.hasMore || state.loadingHistory) return@LaunchedEffect
        snapshotFlow {
            val visible = list.layoutInfo.visibleItemsInfo
            // About three screens ahead, as on the Mac; the list is reversed, so its top is its last index.
            visible.isNotEmpty() && list.layoutInfo.totalItemsCount - 1 - visible.last().index <= 3 * visible.size
        }.first { it }
        loadOlder()
    }
    BackHandler(onBack = onBack)
    var menu by remember { mutableStateOf<ConversationMessage?>(null) }
    menu?.let { MessageMenu(it, onRetrySend, onDeleteUnsent) { menu = null } }
    Column(Modifier.fillMaxSize().background(colors.canvas).navigationBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(end = UiMetrics.GapLarge,
            top = UiMetrics.GapSmall, bottom = UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") }
            Surface(Modifier.weight(1f), shape = MaterialTheme.shapes.extraLarge, color = colors.raised, contentColor = colors.textPrimary) {
                Row(Modifier.heightIn(min = UiMetrics.Touch).padding(horizontal = UiMetrics.GapMedium, vertical = UiMetrics.GapTiny),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                    if (!room.direct) Icon(Icons.Outlined.Tag, null, Modifier.size(UiMetrics.Icon))
                    Column {
                        Text(room.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (room.topic.isNotBlank()) Text(room.topic, style = MaterialTheme.typography.bodyMedium,
                            color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
        HorizontalDivider(color = colors.border)
        Box(Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(Modifier.fillMaxSize(), state = list, reverseLayout = true,
                contentPadding = PaddingValues(vertical = UiMetrics.GapSmall)) {
                items(state.rows.asReversed(), key = { it.id }) { row ->
                    when (row) {
                        is DayDivider -> DayDividerRow(row.timestamp)
                        is ConversationMessage -> LiveMessageRow(row) { menu = it }
                    }
                }
                // The top of the conversation, which also lets an empty one ask for history.
                item(key = "top") {
                    if (!state.hasMore && !state.loading) ConversationIntro(room)
                    else if (state.rows.isNotEmpty()) HistoryProgress(state.loadingHistory)
                }
            }
            (composer.error ?: state.sendError ?: state.error)?.let { message ->
                Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge),
                    action = { TextButton(onClick = onRetry) { Text("Retry") } }) { Text(message) }
            }
        }
        val description = if (room.direct) "Message ${room.name}" else "Message #${room.name}"
        // Slack's composer: a rounded field on a bar under a hairline, with send inside the field.
        HorizontalDivider(color = colors.border)
        Surface(Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapMedium, vertical = UiMetrics.GapSmall),
            shape = MaterialTheme.shapes.extraLarge, color = colors.raised) {
            Row(verticalAlignment = Alignment.Bottom) {
                BasicTextField(composer.text, onDraft, enabled = !composer.loading,
                    modifier = Modifier.weight(1f).heightIn(min = UiMetrics.Touch).padding(start = UiMetrics.GapMedium)
                        .semantics { contentDescription = description },
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.textBody),
                    cursorBrush = SolidColor(colors.accent), maxLines = 5,
                    decorationBox = { inner ->
                        Box(Modifier.padding(vertical = UiMetrics.GapMedium), contentAlignment = Alignment.CenterStart) {
                            if (composer.text.isEmpty()) Text(description, style = MaterialTheme.typography.bodyLarge,
                                color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            inner()
                        }
                    })
                IconButton(onClick = onSend, enabled = !composer.loading && !composer.sending && composer.text.isNotBlank()) {
                    Icon(Icons.AutoMirrored.Outlined.Send, "Send message", tint = if (composer.text.isNotBlank()) colors.accent else colors.textTertiary)
                }
            }
        }
    }
}

/** Tops a conversation loaded back to its start, as in Slack. */
@Composable
private fun ConversationIntro(room: RoomSummary) {
    val colors = SlatrixTheme.colors
    Column(Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSection),
        verticalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        Box(Modifier.size(UiMetrics.ProfileAvatar).background(colors.raised, MaterialTheme.shapes.extraLarge),
            contentAlignment = Alignment.Center) {
            Icon(if (room.direct) Icons.Outlined.Person else Icons.Outlined.Tag, null, Modifier.size(UiMetrics.HeaderAvatar))
        }
        Text(if (room.direct) room.name else "# ${room.name}", style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold, color = colors.textPrimary)
        Text(if (room.direct) "This conversation is just between ${room.name} and you."
            else "This is the very beginning of the #${room.name} channel.",
            style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary)
    }
}

@Composable
private fun DayDividerRow(timestamp: Long) {
    val colors = SlatrixTheme.colors
    val label = remember(timestamp) { dayLabel(timestamp) }
    Box(Modifier.fillMaxWidth().padding(vertical = UiMetrics.GapMedium), contentAlignment = Alignment.Center) {
        HorizontalDivider(color = colors.border)
        Surface(shape = MaterialTheme.shapes.extraLarge, color = colors.canvas, border = BorderStroke(UiMetrics.Divider, colors.border)) {
            Text(label, Modifier.padding(horizontal = UiMetrics.GapMedium, vertical = UiMetrics.GapTiny),
                style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, color = colors.textPrimary)
        }
    }
}

/** Slack's day labels: Today, Yesterday, then "Oct 23rd", with the year once it isn't this one. */
private fun dayLabel(timestamp: Long): String {
    val today = LocalDate.now()
    val day = Instant.ofEpochMilli(timestamp).atZone(ZoneId.systemDefault()).toLocalDate()
    if (day == today) return "Today"
    if (day == today.minusDays(1)) return "Yesterday"
    val date = day.dayOfMonth
    val suffix = if (date in 11..13) "th" else when (date % 10) { 1 -> "st"; 2 -> "nd"; 3 -> "rd"; else -> "th" }
    val month = day.format(DateTimeFormatter.ofPattern("MMM", Locale.getDefault()))
    return "$month $date$suffix" + if (day.year == today.year) "" else ", ${day.year}"
}

@Composable
private fun HistoryProgress(loading: Boolean) {
    var visible by remember { mutableStateOf(false) }
    // Shows after the delay and hides only after as long a gap, so back-to-back pages don't blink it.
    LaunchedEffect(loading) { delay(UiMetrics.ProgressDelayMillis); visible = loading }
    Box(Modifier.fillMaxWidth().height(UiMetrics.Touch), contentAlignment = Alignment.Center) {
        if (visible) CircularProgressIndicator(Modifier.size(UiMetrics.Icon))
    }
}

private fun timeLabel(timestamp: Long): String = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(timestamp))

@Composable
private fun LiveMessageRow(message: ConversationMessage, onMenu: (ConversationMessage) -> Unit) {
    val colors = SlatrixTheme.colors
    val failed = message.sendState == MessageSendState.Failed
    // A grouped row keeps the gutter, so its body lines up and its height doesn't depend on its send state.
    Row(Modifier.fillMaxWidth()
        .combinedClickable(onLongClickLabel = "Message actions", onLongClick = { onMenu(message) }) { if (failed) onMenu(message) }
        .then(if (message.grouped) Modifier else Modifier.padding(top = UiMetrics.GapSmall))
        .padding(start = UiMetrics.GapLarge, end = UiMetrics.GapLarge, bottom = UiMetrics.GapTiny),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        if (message.grouped) Box(Modifier.width(UiMetrics.Avatar), contentAlignment = Alignment.Center) {
            if (failed) Icon(Icons.Outlined.ErrorOutline, "Not sent", Modifier.size(UiMetrics.Icon), tint = colors.destructive)
        } else MessageAvatar(message.initials, message.colorIndex)
        Column(Modifier.weight(1f)) {
            if (!message.grouped) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                Text(message.senderName, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(when (message.sendState) {
                    MessageSendState.Sent -> remember(message.timestamp) { timeLabel(message.timestamp) }
                    MessageSendState.Sending -> "Sending…"
                    MessageSendState.Failed -> "Not sent"
                }, style = MaterialTheme.typography.bodySmall, maxLines = 1, color = if (failed) colors.destructive else colors.textSecondary)
            }
            Text(message.body, style = MaterialTheme.typography.bodyLarge,
                color = if (message.sendState == MessageSendState.Sending) colors.textSecondary else colors.textBody)
        }
    }
}

@Composable
private fun MessageAvatar(initials: String, colorIndex: Int) {
    Box(Modifier.sizeIn(minWidth = UiMetrics.Avatar, minHeight = UiMetrics.Avatar).clip(MaterialTheme.shapes.large)
        .background(DesignTokens.avatarColors[colorIndex]).padding(UiMetrics.GapTiny), contentAlignment = Alignment.Center) {
        Text(initials, style = AvatarStyle.label, color = SlatrixTheme.colors.onAccent, maxLines = 1, softWrap = false)
    }
}

/** Slack's long-press sheet: who sent the message and when, then what can be done with it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MessageMenu(message: ConversationMessage, onRetrySend: (ConversationMessage) -> Unit,
    onDeleteUnsent: (ConversationMessage) -> Unit, onDismiss: () -> Unit) {
    val colors = SlatrixTheme.colors
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    ModalBottomSheet(onDismissRequest = onDismiss, shape = SlatrixTheme.topPanelShape, containerColor = colors.overlay) {
        Column(Modifier.fillMaxWidth().padding(bottom = UiMetrics.GapLarge)) {
            Row(Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
                horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
                Text(message.senderName, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("${dayLabel(message.timestamp)} at ${timeLabel(message.timestamp)}",
                    style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, maxLines = 1)
            }
            if (message.sendState == MessageSendState.Failed) {
                if (message.canRetry) MenuAction(Icons.Outlined.Refresh, "Retry", colors.textPrimary) { onRetrySend(message); onDismiss() }
                MenuAction(Icons.Outlined.Delete, "Delete message", colors.destructive) { onDeleteUnsent(message); onDismiss() }
            }
            if (message.kind in setOf(MessageKind.Text, MessageKind.Notice, MessageKind.Emote)) {
                MenuAction(Icons.Outlined.ContentCopy, "Copy message", colors.textPrimary) {
                    scope.launch {
                        clipboard.setClipEntry(ClipEntry(ClipData.newPlainText(message.senderName, message.body)))
                        onDismiss()
                    }
                }
            }
        }
    }
}

@Composable
private fun MenuAction(icon: ImageVector, label: String, color: Color, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(onClick = onClick).padding(horizontal = UiMetrics.GapLarge),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(UiMetrics.Icon), tint = color)
        Text(label, style = MaterialTheme.typography.bodyLarge, color = color)
    }
}
