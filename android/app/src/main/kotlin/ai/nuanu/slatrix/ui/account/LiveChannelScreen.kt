package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.DayDivider
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
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
    onRetry: () -> Unit, onRetrySend: (ConversationMessage) -> Unit, onDeleteUnsent: (ConversationMessage) -> Unit,
    onOpenThread: (rootEventId: String) -> Unit = {},
    /** Shows the thread this message starts, as Slack's thread page, instead of the channel. */
    threadRoot: String? = null, actions: MessageActions = MessageActions(), composerActions: ComposerActions = ComposerActions(),
    /** Asked, with the oldest message on screen, once the reader reaches the newest of a conversation opened at an older one. */
    onLoadNewer: (anchor: String?) -> Unit = {},
    /** Opens a message where it is, highlighted, as a tap on a reply's quote does. */
    onOpenMessage: (eventId: String) -> Unit = {},
    /** Opens the conversation's details, as a tap on Slack's header pill does. */
    onOpenDetails: () -> Unit = {},
    /** Who else is typing, by name. */
    typing: List<String> = emptyList()) {
    val colors = SlatrixTheme.colors
    val list = rememberLazyListState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var resumed by remember(lifecycle) { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, _ -> resumed = lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    // A jump waits to show until it has scrolled to its message, so the newest rows never flash or count as read.
    val rows by rememberUpdatedState(state.rows)
    var jumped by remember(state.highlight) { mutableStateOf(state.highlight == null) }
    val latest = state.rows.lastOrNull { it is ConversationMessage && it.eventId != null } as ConversationMessage?
    val read by rememberUpdatedState(onRead)
    LaunchedEffect(latest?.id, latest?.eventId, resumed, jumped) {
        val event = latest?.eventId ?: return@LaunchedEffect
        if (!resumed || !jumped) return@LaunchedEffect
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
        if (following && !state.focused || newest?.own == true && newest.sendState == MessageSendState.Sending) list.scrollToItem(0)
    }
    // A jump shows its message a third of the way up and highlights it briefly, as on the Mac, once.
    var lit by remember(state.highlight) { mutableStateOf<String?>(null) }
    LaunchedEffect(state.highlight) {
        val target = state.highlight ?: return@LaunchedEffect
        val index = snapshotFlow { rows.indexOfLast { (it as? ConversationMessage)?.eventId == target } }.first { it >= 0 }
        following = false
        try {
            list.scrollToItem(rows.size - 1 - index)
            // The list is reversed, so the message sits at the bottom; newer ones below lift it a third of the way up.
            list.scrollBy(-list.layoutInfo.viewportSize.height / 3f)
            jumped = true
            lit = target
            delay(UiMetrics.HighlightMillis)
        } finally {
            jumped = true
            lit = null
        }
    }
    val loadNewer by rememberUpdatedState(onLoadNewer)
    // Asks each time the newest row comes into view, and again after a page while it stays there.
    LaunchedEffect(list, state.focused && jumped, newest?.id) {
        if (!state.focused || !jumped) return@LaunchedEffect
        snapshotFlow { list.layoutInfo.visibleItemsInfo.any { it.index == 0 } }.distinctUntilChanged().collect { visible ->
            if (!visible) return@collect
            // The oldest message on screen; the list is reversed, so it has the highest index.
            val top = list.layoutInfo.visibleItemsInfo.maxOf { it.index }
            loadNewer((top downTo 0).firstNotNullOfOrNull { (rows.asReversed().getOrNull(it) as? ConversationMessage)?.eventId })
        }
    }
    val loadOlder by rememberUpdatedState(onLoadOlder)
    // Asks again after every page while the top stays near, so pages of hidden events don't stall it.
    val canPage = !state.loading && state.hasMore && !state.loadingHistory && state.error == null
    LaunchedEffect(list, canPage) {
        // Waits for the cached messages, so a conversation that has plenty doesn't page on open, and after a
        // failure waits for Retry.
        if (!canPage) return@LaunchedEffect
        snapshotFlow {
            val visible = list.layoutInfo.visibleItemsInfo
            // About three screens ahead, as on the Mac; the list is reversed, so its top is its last index.
            visible.isNotEmpty() && list.layoutInfo.totalItemsCount - 1 - visible.last().index <= 3 * visible.size
        }.first { it }
        loadOlder()
    }
    BackHandler(onBack = onBack)
    var menu by remember { mutableStateOf<ConversationMessage?>(null) }
    // Inside a thread, Reply has nowhere further to go.
    menu?.let { MessageActionsHost(it, actions, onOpenThread.takeIf { threadRoot == null }, onRetrySend, onDeleteUnsent) { menu = null } }
    var reacted by remember { mutableStateOf<ConversationMessage?>(null) }
    reacted?.let { ReactionsSheet(it.reactions, state.rows, state.ownUserId) { reacted = null } }
    Column(Modifier.fillMaxSize().background(colors.canvas).navigationBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(end = UiMetrics.GapLarge,
            top = UiMetrics.GapSmall, bottom = UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") }
            if (threadRoot != null) Column(Modifier.weight(1f).padding(start = UiMetrics.GapSection + UiMetrics.GapLarge)) {
                Text("Thread", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = colors.textPrimary)
                Text(if (room.direct) room.name else "#${room.name}", style = MaterialTheme.typography.bodyMedium,
                    color = colors.accent, maxLines = 1, overflow = TextOverflow.Ellipsis)
            } else Surface(onOpenDetails, Modifier.weight(1f), shape = MaterialTheme.shapes.extraLarge, color = colors.raised, contentColor = colors.textPrimary) {
                Row(Modifier.heightIn(min = UiMetrics.Touch).padding(horizontal = UiMetrics.GapMedium, vertical = UiMetrics.GapTiny),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                    if (!room.direct) Icon(if (room.isPrivate) SlackIcons.Lock else SlackIcons.Hash, null, Modifier.size(UiMetrics.Icon))
                    Column {
                        Text(room.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                        // Slack's member line, as the Mac's facepile, except for a direct message with one person. Held empty
                        // until the count is known, so the pill keeps its height.
                        if (!room.direct || room.memberCount > 2) Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(when (room.memberCount) { 0 -> ""; 1 -> "1 member"; else -> "${room.memberCount} members" },
                                style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, maxLines = 1)
                            if (room.memberCount > 0) Icon(SlackIcons.ChevronDown, null, Modifier.size(UiMetrics.SmallIcon),
                                tint = colors.textSecondary)
                        }
                    }
                }
            }
        }
        HorizontalDivider(color = colors.border)
        Box(Modifier.weight(1f).fillMaxWidth()) {
            val rows = state.rows
            // A reset re-pages the thread; the last count stays until the new one is known, so the bar doesn't blank.
            var replies by remember { mutableStateOf<Int?>(null) }
            if (threadRoot != null && !state.hasMore) {
                replies = rows.count { it is ConversationMessage && it.eventId != null && it.eventId != threadRoot }
            }
            val firstReply = remember(rows, threadRoot) {
                rows.getOrNull(rows.indexOfFirst { (it as? ConversationMessage)?.eventId == threadRoot } + 1)?.id.takeIf { threadRoot != null }
            }
            // A thread reads down from its root, as in Slack, so a short one sits at the top.
            LazyColumn(Modifier.fillMaxSize().alpha(if (jumped || rows.none { (it as? ConversationMessage)?.eventId == state.highlight }) 1f else 0f),
                state = list, reverseLayout = true,
                verticalArrangement = if (threadRoot != null) Arrangement.Top else Arrangement.Bottom,
                contentPadding = PaddingValues(vertical = UiMetrics.GapSmall)) {
                items(rows.asReversed(), key = { it.id }) { row ->
                    when (row) {
                        is DayDivider -> DayDividerRow(row.timestamp)
                        is ConversationMessage -> Box(if (lit != null && row.eventId == lit) Modifier.background(colors.highlight) else Modifier) {
                            if (threadRoot != null && row.eventId == threadRoot) Column {
                                LiveMessageRow(row, state.ownUserId, actions.onReact, { reacted = it }, null, onOpenMessage) { menu = it }
                                // Counted once the whole thread has loaded; until then the bar keeps its place, so nothing moves.
                                RepliesBar(replies)
                            // The first reply starts under the replies bar, so it shows its sender again.
                            } else LiveMessageRow(if (row.id == firstReply) row.copy(grouped = false) else row, state.ownUserId,
                                actions.onReact, { reacted = it }, onOpenThread.takeIf { threadRoot == null }, onOpenMessage) { menu = it }
                        }
                    }
                }
                // The top of the conversation, which also lets an empty one ask for history; a thread tops out at its root.
                item(key = "top") {
                    when {
                        !state.hasMore && !state.loading -> if (threadRoot == null) ConversationIntro(room)
                        // A thread with its root on screen waits in its replies bar; one opened without it shows the wait.
                        threadRoot != null -> if (state.rows.isEmpty()) HistoryProgress(true)
                        state.rows.isNotEmpty() -> HistoryProgress(state.loadingHistory)
                    }
                }
            }
            state.notice?.let { Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge)) { Text(it) } }
            (composer.error ?: state.sendError ?: state.error)?.let { message ->
                Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge),
                    action = { TextButton(onClick = onRetry) { Text("Retry") } }) { Text(message) }
            }
        }
        val placeholder = when {
            threadRoot != null -> "Add a reply"
            room.direct -> "Message ${room.name}"
            else -> "Message #${room.name}"
        }
        val senders = remember(state.rows) { state.rows.asReversed().mapNotNull { (it as? ConversationMessage)?.senderId } }
        TypingLine(typing)
        if (room.canPost) MessageComposer(placeholder, composer, onDraft, onSend, composerActions, senders) else CannotPost()
    }
}

/** The Mac's line in place of the composer, in a panel like the composer's. */
@Composable
private fun CannotPost() {
    val colors = SlatrixTheme.colors
    Text("You don’t have permission to post in this channel.", Modifier.fillMaxWidth()
        .border(UiMetrics.Divider, colors.border, SlatrixTheme.topPanelShape).background(colors.canvas, SlatrixTheme.topPanelShape)
        .heightIn(min = UiMetrics.ComposerMinHeight).wrapContentHeight().padding(horizontal = UiMetrics.GapLarge),
        style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, textAlign = TextAlign.Center)
}

/** Slack's bar between a thread's root and its replies. */
@Composable
private fun RepliesBar(count: Int?) {
    val colors = SlatrixTheme.colors
    if (count == 0) return
    Column(Modifier.fillMaxWidth().padding(top = UiMetrics.GapSmall)) {
        HorizontalDivider(color = colors.border)
        Text(when (count) { null -> ""; 1 -> "1 reply"; else -> "$count replies" },
            Modifier.heightIn(min = UiMetrics.Touch).padding(horizontal = UiMetrics.GapLarge).wrapContentHeight(),
            style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, color = colors.textPrimary)
        HorizontalDivider(color = colors.border)
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
internal fun dayLabel(timestamp: Long): String {
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

internal fun timeLabel(timestamp: Long): String = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(timestamp))

@Composable
private fun LiveMessageRow(message: ConversationMessage, me: String?, onReact: ((ConversationMessage, String) -> Unit)?,
    onShowReactions: (ConversationMessage) -> Unit, onOpenThread: ((String) -> Unit)?, onOpenReply: (String) -> Unit,
    onMenu: (ConversationMessage) -> Unit) {
    val colors = SlatrixTheme.colors
    val failed = message.sendState == MessageSendState.Failed
    // A grouped row keeps the gutter, so its body lines up and its height doesn't depend on its send state.
    Row(Modifier.fillMaxWidth()
        // Only a failed message answers a tap, as in Slack; any message opens its sheet on a long press.
        .then(if (failed) Modifier.combinedClickable(onClickLabel = "Message actions", onLongClickLabel = "Message actions",
            onLongClick = { onMenu(message) }) { onMenu(message) }
        else Modifier.pointerInput(message) { detectTapGestures(onLongPress = { onMenu(message) }) }
            .semantics(mergeDescendants = true) { onLongClick("Message actions") { onMenu(message); true } })
        .then(if (message.grouped) Modifier else Modifier.padding(top = UiMetrics.GapSmall))
        .padding(start = UiMetrics.GapLarge, end = UiMetrics.GapLarge, bottom = UiMetrics.GapTiny),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        if (message.grouped) Box(Modifier.width(UiMetrics.Avatar), contentAlignment = Alignment.Center) {
            if (failed) Icon(Icons.Outlined.ErrorOutline, "Not sent", Modifier.size(UiMetrics.Icon), tint = colors.destructive)
        } else LiveAvatar(message.initials, message.colorIndex)
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
            message.replyTo?.let { reply -> ReplyQuote(reply) { onOpenReply(reply.eventId) } }
            Box {
                MessageBody(message, if (message.sendState == MessageSendState.Sending) colors.textSecondary else colors.textBody, me)
                // In the row's bottom padding, so the bar comes and goes without moving anything.
                message.uploadProgress?.let {
                    LinearProgressIndicator({ it }, Modifier.align(Alignment.BottomStart).fillMaxWidth().height(UiMetrics.GapTiny)
                        .offset(y = UiMetrics.GapTiny))
                }
            }
            if (message.reactions.isNotEmpty()) {
                Reactions(message.reactions, onReact?.let { react -> { key: String -> react(message, key) } }) { onShowReactions(message) }
            }
            val root = message.eventId
            // Inside a thread the root's replies bar says it instead.
            if (message.thread != null && root != null && onOpenThread != null) ThreadReplies(message.thread) { onOpenThread(root) }
        }
    }
}
