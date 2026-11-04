package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationRow
import ai.nuanu.slatrix.core.caption
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.DayDivider
import ai.nuanu.slatrix.core.MessageAttachment
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.ComposerTarget
import ai.nuanu.slatrix.core.ThreadOrigin
import ai.nuanu.slatrix.ui.designsystem.Motion
import ai.nuanu.slatrix.ui.designsystem.OnAccentFill
import ai.nuanu.slatrix.ui.designsystem.bubble
import ai.nuanu.slatrix.ui.designsystem.bubbleShape
import ai.nuanu.slatrix.ui.designsystem.glassBar
import ai.nuanu.slatrix.ui.designsystem.glassSource
import ai.nuanu.slatrix.ui.designsystem.rememberGlass
import ai.nuanu.slatrix.ui.designsystem.wallpaper
import dev.chrisbanes.haze.HazeState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import ai.nuanu.slatrix.ui.designsystem.rememberPredictiveBack
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import android.content.ClipData
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.*
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
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
import androidx.compose.ui.unit.lerp
import kotlin.math.roundToInt

@Composable
fun LiveChannelScreen(room: RoomSummary, state: ConversationState, composer: ComposerState,
    onDraft: (String) -> Unit, onSend: () -> Unit, onBack: () -> Unit, onLoadOlder: () -> Unit, onRead: (String) -> Unit,
    onRetry: () -> Unit, onRetrySend: (ConversationMessage) -> Unit, onDeleteUnsent: (ConversationMessage) -> Unit,
    onOpenThread: (rootEventId: String) -> Unit = {},
    /** Shows the thread this message starts, as Slack's thread page, instead of the channel. */
    threadRoot: String? = null, actions: MessageActions = MessageActions(), composerActions: ComposerActions = ComposerActions(),
    /** Asked, with the oldest message on screen, once the reader reaches the newest of a conversation opened at an older one. */
    onLoadNewer: (anchor: String?) -> Unit = {},
    /** Takes a conversation opened at an older message to its newest, live. */
    onShowNewest: () -> Unit = {},
    /** Opens a message where it is, highlighted, as a tap on a reply's quote does. */
    onOpenMessage: (eventId: String) -> Unit = {},
    loadPicture: PictureLoader = { _, _, _, _ -> null },
    onOpenFile: suspend (MessageAttachment) -> String? = { null },
    loadFile: FileLoader = { null },
    /** Opens the conversation's details, as a tap on Slack's header pill does. */
    onOpenDetails: () -> Unit = {},
    /** Who else is typing, by name. */
    typing: List<String> = emptyList(),
    /** Opens someone's profile, from a sender's name or picture or a mention. */
    onPerson: (userId: String) -> Unit = {},
    /** The thread a copy of a thread reply came from, which its row names; null when the reply isn't in a thread. */
    loadThreadOrigin: suspend (replyEventId: String) -> ThreadOrigin? = { null }) {
    val colors = SlatrixTheme.colors
    val list = rememberLazyListState()
    val videos = rememberVideoPlayback(loadFile)
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var resumed by remember(lifecycle) { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, _ -> resumed = lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    // A jump waits to show until it has scrolled to its message, so the newest rows never flash or count as read.
    val rows by rememberUpdatedState(state.rows)
    // The New line stays where it first showed, as on the Mac, though reading moves the SDK's marker past the newest. A
    // resumed conversation opens with it at the top, decided when its first rows show, unless a jump says where.
    // Where the reader left it: the row at the bottom of the screen and how far it was scrolled, as the Mac anchors a row;
    // null at the newest. Kept while the conversation is left, and restored when its rows still hold that row.
    var place by rememberSaveable { mutableStateOf<Pair<String, Int>?>(null) }
    val newLine = remember { object { var at: String? = null; var start: String? = null; var decided = false; var back: Pair<String, Int>? = null } }
    if (newLine.at == null && state.rows.any { it is ConversationMessage && it.eventId != null && it.eventId == state.firstUnread }) {
        newLine.at = state.firstUnread
    }
    if (!newLine.decided && !state.loading && state.rows.isNotEmpty()) {
        newLine.decided = true
        newLine.start = newLine.at.takeIf { state.startsAtUnread && state.highlight == null }
        newLine.back = place?.takeIf { (id) -> newLine.start == null && state.highlight == null && state.rows.any { it.id == id } }
    }
    val line = newLine.at
    val opensAt = state.highlight ?: newLine.start ?: newLine.back?.first
    fun opens(row: ConversationRow) = row.id == opensAt || (row as? ConversationMessage)?.eventId == opensAt
    var jumped by remember(opensAt) { mutableStateOf(opensAt == null) }
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
    LaunchedEffect(list, jumped) {
        if (!jumped) return@LaunchedEffect
        snapshotFlow { list.firstVisibleItemIndex to list.firstVisibleItemScrollOffset }.collect { (index, offset) ->
            place = if (index == 0 && offset == 0) null else rows.asReversed().getOrNull(index)?.let { it.id to offset }
        }
    }
    val newest = state.rows.lastOrNull() as? ConversationMessage
    var following by remember { mutableStateOf(true) }
    LaunchedEffect(list) {
        snapshotFlow { list.isScrollInProgress }.collect { scrolling ->
            following = !scrolling && list.firstVisibleItemIndex == 0 && list.firstVisibleItemScrollOffset == 0
        }
    }
    LaunchedEffect(newest?.id) {
        // Not while it opens somewhere else, which scrolls there instead.
        if (following && jumped && !state.focused || newest?.own == true && newest.sendState == MessageSendState.Sending) list.scrollToItem(0)
    }
    // A jump shows its message a third of the way up and highlights it briefly, as on the Mac, once.
    var lit by remember(opensAt) { mutableStateOf<String?>(null) }
    LaunchedEffect(opensAt) {
        val target = opensAt ?: return@LaunchedEffect
        val index = snapshotFlow { rows.indexOfLast { it.id == target || (it as? ConversationMessage)?.eventId == target } }.first { it >= 0 }
        following = false
        try {
            newLine.back?.takeIf { it.first == target }?.let { (_, offset) ->
                list.scrollToItem(rows.size - 1 - index, offset)
                return@LaunchedEffect
            }
            list.scrollToItem(rows.size - 1 - index)
            if (target == newLine.start) {
                // The line tops the screen with the unread messages under it; fewer than a screenful sit at the bottom.
                val item = list.layoutInfo.visibleItemsInfo.firstOrNull { it.index == rows.size - 1 - index }
                val info = list.layoutInfo
                val visible = info.viewportSize.height - info.beforeContentPadding - info.afterContentPadding
                list.scrollBy(-(visible - (item?.size ?: 0)).coerceAtLeast(0).toFloat())
                return@LaunchedEffect
            }
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
    // Keyed on the oldest row too, since a page from the local cache can land before the screen ever sees it loading.
    LaunchedEffect(list, canPage, state.rows.firstOrNull()?.id) {
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
    val back = rememberPredictiveBack(onBack = onBack)
    var menu by remember { mutableStateOf<Pair<ConversationMessage, LiftedMessage?>?>(null) }
    // Inside a thread, Reply has nowhere further to go.
    menu?.let { (message, lifted) ->
        MessageActionsHost(message, actions, onOpenThread.takeIf { threadRoot == null }, onRetrySend, onDeleteUnsent, lifted) { menu = null }
    }
    var reacted by remember { mutableStateOf<ConversationMessage?>(null) }
    // The row and its tile's pixels, saved, so the viewer stays open on the same image when the phone turns.
    var viewing by rememberSaveable { mutableStateOf<Pair<String, Pair<Int, Int>>?>(null) }
    viewing?.let { (id, tile) ->
        (state.rows.find { it.id == id } as? ConversationMessage)?.attachment?.let { MediaViewer(it, tile, loadPicture) { viewing = null } }
    }
    val files = rememberCoroutineScope()
    // A file opens from the screen, not its row, so scrolling the row away doesn't cancel the download.
    var opening by remember { mutableStateOf(emptySet<String>()) }
    var fileError by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(fileError) { if (fileError != null) { delay(UiMetrics.NoticeMillis); fileError = null } }
    val openFile = { message: ConversationMessage ->
        val attachment = message.attachment
        if (attachment != null && message.id !in opening) files.launch {
            opening += message.id
            try { onOpenFile(attachment)?.let { fileError = it } } finally { opening -= message.id }
        }
    }
    reacted?.let { ReactionsSheet(it.reactions, state.rows, state.ownUserId) { reacted = null } }
    val glass = rememberGlass()
    // The header floats over the messages, which start under it; the scaffold measures it first, so they never move.
    Scaffold(Modifier.graphicsLayer {
        // A back swipe slides the conversation off under the finger, as a pushed page leaves.
        alpha = 1 - back.value
        translationX = back.value * Motion.PushDistance * size.width
    }, topBar = { ChatHeader(room, threadRoot != null, typing, glass, onBack, onOpenDetails) },
        containerColor = colors.canvas, contentWindowInsets = WindowInsets(0)) { bars ->
    val header = bars.calculateTopPadding()
    Column(Modifier.fillMaxSize().wallpaper().navigationBarsPadding().imePadding()) {
        // Only the messages pass under the header, so typing never redraws what it blurs.
        Box(Modifier.weight(1f).fillMaxWidth().glassSource(glass)) {
            val rows = state.rows
            // A reset re-pages the thread; the last count stays until the new one is known, so the bar doesn't blank.
            var replies by remember { mutableStateOf<Int?>(null) }
            if (threadRoot != null && !state.hasMore) {
                replies = rows.count { it is ConversationMessage && it.eventId != null && it.eventId != threadRoot }
            }
            val firstReply = remember(rows, threadRoot) {
                rows.getOrNull(rows.indexOfFirst { (it as? ConversationMessage)?.eventId == threadRoot } + 1)?.id.takeIf { threadRoot != null }
            }
            // A row that starts a run again: after the replies bar or the New line, so it shows its sender.
            fun restarts(row: ConversationMessage) = row.id == firstReply || line != null && row.eventId == line
            // A thread reads down from its root, as in Slack, so a short one sits at the top, right under the header.
            LazyColumn(Modifier.fillMaxSize().alpha(if (jumped || rows.none(::opens)) 1f else 0f),
                state = list, reverseLayout = true,
                verticalArrangement = if (threadRoot != null) Arrangement.Top else Arrangement.Bottom,
                contentPadding = PaddingValues(top = header + UiMetrics.GapSmall, bottom = UiMetrics.GapSmall)) {
                itemsIndexed(rows.asReversed(), key = { _, row -> row.id }) { index, row ->
                    when (row) {
                        is DayDivider -> DayDividerRow(row.timestamp)
                        is ConversationMessage -> Column(if (lit != null && row.eventId == lit) Modifier.background(colors.highlight) else Modifier) {
                            val first = line != null && row.eventId == line
                            if (first) NewLine()
                            // The newer row, below; a run of one sender's bubbles shows their picture by its last.
                            val next = rows.getOrNull(rows.size - index) as? ConversationMessage
                            val last = next == null || !next.grouped || restarts(next)
                            val root = threadRoot != null && row.eventId == threadRoot
                            // The menu lifts the row as drawn here, so it draws the same row again.
                            val draw: @Composable ((ConversationMessage, Float?) -> Unit) -> Unit = { onMenu ->
                                LiveMessageRow(if (root || restarts(row)) row.copy(grouped = false) else row, root || last, state.ownUserId,
                                    actions.onReact, { reacted = it }, onOpenThread.takeIf { threadRoot == null }, onOpenMessage,
                                    loadPicture, videos, row.id in opening, openFile, { tile -> viewing = row.id to tile }, onPerson,
                                    loadThreadOrigin, onMenu)
                            }
                            draw { message, top -> menu = message to top?.let { LiftedMessage(it) { draw { _, _ -> } } } }
                            // Counted once the whole thread has loaded; until then the bar keeps its place, so nothing moves.
                            if (root) RepliesBar(replies)
                        }
                    }
                }
                // The top of the conversation, which also lets an empty one ask for history; a thread tops out at its root.
                item(key = "top") {
                    when {
                        !state.hasMore && !state.loading -> if (threadRoot == null) ConversationIntro(room)
                        // A thread with its root on screen waits in its replies bar; one opened without it shows the wait.
                        threadRoot != null -> if (state.rows.isEmpty()) HistoryProgress(true)
                        // With nothing cached, the first page loads with no message to sit above.
                        else -> HistoryProgress(state.loadingHistory || state.rows.isEmpty() && state.loading)
                    }
                }
            }
            // Slack's way back to the newest message, once the reader scrolls up or opened an older one.
            val away by remember { derivedStateOf { list.firstVisibleItemIndex > 0 } }
            val jumps = rememberCoroutineScope()
            androidx.compose.animation.AnimatedVisibility(jumped && (state.focused || away), Modifier.align(Alignment.BottomEnd).padding(UiMetrics.GapLarge),
                enter = fadeIn(Motion.pane()), exit = ExitTransition.None) {
                Surface({
                    following = true
                    if (state.focused) onShowNewest() else jumps.launch { list.scrollToItem(0) }
                }, Modifier.size(UiMetrics.Touch).semantics { contentDescription = "Jump to recent messages" }, shape = CircleShape,
                    color = colors.bubbleIn, contentColor = colors.textSecondary, shadowElevation = UiMetrics.Hairline * 2) {
                    Box(contentAlignment = Alignment.Center) { Icon(Icons.Outlined.ArrowDownward, null, Modifier.size(UiMetrics.Icon)) }
                }
            }
            Box(Modifier.padding(top = header)) { OfflineBanner() }
            state.notice?.let { Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge)) { Text(it) } }
            (composer.error ?: state.sendError ?: state.error)?.let { message ->
                Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge),
                    action = { TextButton(onClick = onRetry) { Text("Retry") } }) { Text(message) }
            } ?: fileError?.let { Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge)) { Text(it) } }
        }
        val placeholder = when {
            threadRoot != null -> "Add a reply"
            room.direct || room.isPrivate -> "Message ${room.name}"
            else -> "Message #${room.name}"
        }
        val senders = remember(state.rows) { state.rows.asReversed().mapNotNull { (it as? ConversationMessage)?.senderId } }
        if (room.canPost) MessageComposer(placeholder, composer, onDraft, onSend, composerActions, senders,
            aboveField = if (threadRoot != null && composer.target !is ComposerTarget.Edit) {
                { AlsoSendTo(room, composer.alsoToChannel, composerActions.onAlsoToChannel) }
            } else null) else CannotPost()
    }
    }
}

/** The glass header over a conversation: back, who or what it is, and who's typing or how many are in it. */
@Composable
private fun ChatHeader(room: RoomSummary, thread: Boolean, typing: List<String>, glass: HazeState, onBack: () -> Unit,
    onOpenDetails: () -> Unit) {
    val colors = SlatrixTheme.colors
    Row(Modifier.fillMaxWidth().glassBar(glass).statusBarsPadding().heightIn(min = UiMetrics.HeaderRow)
        .padding(horizontal = UiMetrics.GapTiny), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") }
        val subtitle = when {
            typing.isNotEmpty() -> typingLabel(typing)
            thread -> if (room.direct) room.name else "#${room.name}"
            // Slack's member line, except for a direct message with one person; blank until the count is known.
            !room.direct || room.memberCount > 2 -> if (room.memberCount == 0) "" else membersLabel(room.memberCount.toLong())
            else -> null
        }
        val lines = @Composable {
            Column(Modifier.padding(start = UiMetrics.GapMedium)) {
                Text(if (thread) "Thread" else room.name, style = MaterialTheme.typography.titleMedium, color = colors.textPrimary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                subtitle?.let {
                    Text(it, Modifier.semantics { liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.bodyMedium,
                        color = if (typing.isNotEmpty()) colors.accent else colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        if (thread) Box(Modifier.weight(1f)) { lines() }
        else Row(Modifier.weight(1f).heightIn(min = UiMetrics.Touch).clip(MaterialTheme.shapes.medium)
            .clickable(role = Role.Button, onClickLabel = "Conversation details", onClick = onOpenDetails),
            verticalAlignment = Alignment.CenterVertically) {
            Lead {
                if (room.direct) LiveAvatar(room.initials, room.colorIndex, leadSize(), room.avatarUrl)
                else ChannelGlyph(room.isPrivate, colors.textPrimary)
            }
            lines()
        }
        if (!thread) IconButton(onClick = onOpenDetails) {
            Icon(Icons.Outlined.MoreVert, "Conversation details", tint = colors.textSecondary)
        }
    }
}

/** Slack's checkbox over a thread's composer that sends the reply to its channel too. */
@Composable
private fun AlsoSendTo(room: RoomSummary, checked: Boolean, onChange: (Boolean) -> Unit) {
    val colors = SlatrixTheme.colors
    val style = MaterialTheme.typography.bodyLarge
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).toggleable(checked, role = Role.Checkbox, onValueChange = onChange)
        .padding(horizontal = UiMetrics.GapMedium), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
        Checkbox(checked, null, colors = CheckboxDefaults.colors(checkedColor = colors.accent, uncheckedColor = colors.textSecondary,
            checkmarkColor = colors.canvas))
        if (room.direct) Text("Also send as direct message", style = style, color = colors.textPrimary)
        else {
            Text("Also send to", style = style, color = colors.textPrimary)
            // The channel as its header names it: a private one by its lock.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(if (room.isPrivate) SlackIcons.Lock else SlackIcons.Hash, if (room.isPrivate) "Private channel" else null,
                    Modifier.size(UiMetrics.SmallIcon), tint = colors.textPrimary)
                Text(room.name, style = style, fontWeight = FontWeight.Bold, color = colors.textPrimary, maxLines = 1,
                    overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** Slack's red rule above the first unread message, with New at its end. */
@Composable
private fun NewLine() {
    val colors = SlatrixTheme.colors
    Row(Modifier.fillMaxWidth().padding(start = UiMetrics.GapLarge, end = UiMetrics.GapLarge, top = UiMetrics.GapSmall),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
        HorizontalDivider(Modifier.weight(1f), color = colors.destructive)
        Text("New", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = colors.destructive)
    }
}

/** The Mac's line in place of the composer, in a panel like the composer's. */
@Composable
private fun CannotPost() {
    val colors = SlatrixTheme.colors
    Text("You don’t have permission to post in this channel.", Modifier.fillMaxWidth().padding(UiMetrics.GapSmall)
        .clip(MaterialTheme.shapes.extraLarge).background(colors.field)
        .heightIn(min = UiMetrics.Touch).wrapContentHeight().padding(horizontal = UiMetrics.GapLarge),
        style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, textAlign = TextAlign.Center)
}

internal fun membersLabel(count: Long) = if (count == 1L) "1 member" else "$count members"

/** Slack's bar between a thread's root and its replies. */
@Composable
private fun RepliesBar(count: Int?) {
    val colors = SlatrixTheme.colors
    if (count == 0) return
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).padding(horizontal = UiMetrics.GapLarge),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        HorizontalDivider(Modifier.weight(1f), color = colors.borderStrong)
        Text(when (count) { null -> ""; 1 -> "1 reply"; else -> "$count replies" }, style = MaterialTheme.typography.labelMedium,
            color = colors.textSecondary)
        HorizontalDivider(Modifier.weight(1f), color = colors.borderStrong)
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
            // A private channel shows its lock, as the header and the Mac do, and its name without a hash.
            when {
                room.direct -> Icon(Icons.Outlined.Person, null, Modifier.size(UiMetrics.HeaderAvatar))
                room.isPrivate -> Icon(SlackIcons.Lock, "Private channel", Modifier.size(UiMetrics.HeaderAvatar))
                else -> Icon(SlackIcons.Hash, null, Modifier.size(UiMetrics.HeaderAvatar))
            }
        }
        Text(if (room.direct || room.isPrivate) room.name else "# ${room.name}", style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold, color = colors.textPrimary)
        Text(when {
            room.direct -> "This conversation is just between ${room.name} and you."
            room.isPrivate -> "This is the very beginning of the ${room.name} channel."
            else -> "This is the very beginning of the #${room.name} channel."
        },
            style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary)
    }
}

@Composable
private fun DayDividerRow(timestamp: Long) {
    val colors = SlatrixTheme.colors
    val label = remember(timestamp) { dayLabel(timestamp) }
    Box(Modifier.fillMaxWidth().padding(vertical = UiMetrics.GapSmall), contentAlignment = Alignment.Center) {
        Text(label, Modifier.clip(CircleShape).background(colors.dateChip)
            .padding(horizontal = UiMetrics.GapMedium, vertical = UiMetrics.GapTiny),
            style = MaterialTheme.typography.labelMedium, color = colors.onDateChip)
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

/**
 * A message as a bubble: others' on the left in white, their picture by the last of a run and their name, in their
 * color, atop the first; yours on the right in the accent. The time sits inside, after the last line when it fits.
 */
@Composable
private fun LiveMessageRow(message: ConversationMessage, lastOfRun: Boolean, me: String?, onReact: ((ConversationMessage, String) -> Unit)?,
    onShowReactions: (ConversationMessage) -> Unit, onOpenThread: ((String) -> Unit)?, onOpenReply: (String) -> Unit,
    loadPicture: PictureLoader, videos: VideoPlayback, opening: Boolean, onOpenFile: (ConversationMessage) -> Unit, onView: (tile: Pair<Int, Int>) -> Unit,
    onPerson: (String) -> Unit, loadThreadOrigin: suspend (String) -> ThreadOrigin?,
    onMenu: (ConversationMessage, top: Float?) -> Unit) {
    val colors = SlatrixTheme.colors
    val failed = message.sendState == MessageSendState.Failed
    val own = message.own
    // Kept without state, so scrolling never recomposes for it; read only when the menu opens over the row.
    val placed = remember { arrayOfNulls<LayoutCoordinates>(1) }
    fun menu() = onMenu(message, placed[0]?.takeIf { it.isAttached }?.positionInWindow()?.y)
    Row(Modifier.fillMaxWidth().onPlaced { placed[0] = it }
        // Only a failed message answers a tap, as in Slack; any message opens its menu on a long press.
        .then(if (failed) Modifier.combinedClickable(onClickLabel = "Message actions", onLongClickLabel = "Message actions",
            onLongClick = ::menu, onClick = ::menu)
        else Modifier.pointerInput(message) { detectTapGestures(onLongPress = { menu() }) }
            .semantics(mergeDescendants = true) { onLongClick("Message actions") { menu(); true } })
        .padding(top = if (message.grouped) UiMetrics.Hairline * 4 else UiMetrics.GapSmall)
        .layout { measurable, constraints ->
            val gutter = if (own) (constraints.maxWidth * UiMetrics.BubbleGutter).roundToInt()
            else lerp(UiMetrics.IncomingGutterNarrow, UiMetrics.IncomingGutterWide,
                ((constraints.maxWidth.toDp() - UiMetrics.NarrowPhone) / (UiMetrics.WidePhone - UiMetrics.NarrowPhone)).coerceIn(0f, 1f)).roundToPx()
            val width = (constraints.maxWidth - gutter).coerceAtLeast(0)
            val row = measurable.measure(constraints.copy(minWidth = width, maxWidth = width))
            layout(constraints.maxWidth, row.height) { row.placeRelative(if (own) gutter else 0, 0) }
        }
        // The inset sits only on the author's side; the far side is the gutter alone.
        .then(if (own) Modifier.padding(end = UiMetrics.GapSmall) else Modifier.padding(start = UiMetrics.GapSmall)),
        horizontalArrangement = if (own) Arrangement.spacedBy(UiMetrics.GapSmall, Alignment.End) else Arrangement.spacedBy(UiMetrics.GapSmall),
        verticalAlignment = Alignment.Bottom) {
        if (own && failed) Icon(Icons.Outlined.ErrorOutline, "Not sent", Modifier.padding(bottom = UiMetrics.GapSmall).size(UiMetrics.Icon),
            tint = colors.destructive)
        // Every one of a run keeps the picture's room, so their bubbles line up.
        if (!own) Box(Modifier.size(UiMetrics.FeedAvatar)) {
            if (lastOfRun) Box(Modifier.clip(CircleShape).clickable(role = Role.Button) { onPerson(message.senderId) }
                .semantics(mergeDescendants = true) { contentDescription = "${message.senderName}’s profile" }) {
                LiveAvatar(message.initials, message.colorIndex, UiMetrics.FeedAvatar, message.avatarUrl)
            }
        }
        val shape = remember(own, message.grouped) { bubbleShape(own, message.grouped) }
        val bubble = @Composable {
            val fill = SlatrixTheme.colors
            Box(Modifier.weight(1f, fill = false).bubble(shape, fill.bubbleIn, if (own) fill.bubbleIn.copy(alpha = 0f) else fill.bubbleEdge)) {
            val attachment = message.attachment
            // A picture or video runs to the bubble's edge with its time on it, as in a messenger; the rest keeps the text's inset.
            val media = attachment?.kind == MessageAttachment.Kind.Image || attachment?.kind == MessageAttachment.Kind.Video
            val inset = if (media) Modifier.padding(horizontal = UiMetrics.GapMedium - UiMetrics.GapTiny) else Modifier
            // An attachment's text is its caption; without one it is the file's name, which the attachment shows.
            val body: (@Composable () -> Unit)? = if (attachment == null || message.caption != null) {
                { MessageBody(message, if (message.sendState == MessageSendState.Sending) fill.textSecondary else fill.textBody, me, onPerson) }
            } else null
            val time = @Composable { color: Color ->
                Text(when (message.sendState) {
                    MessageSendState.Sent -> remember(message.timestamp) { timeLabel(message.timestamp) }
                    MessageSendState.Sending -> "Sending…"
                    MessageSendState.Failed -> "Not sent"
                }, style = MaterialTheme.typography.labelSmall, maxLines = 1, color = color)
            }
            val timeColor = if (failed && !own) fill.destructive else fill.textSecondary
            Column(Modifier.padding(if (media) PaddingValues(UiMetrics.GapTiny)
                else PaddingValues(horizontal = UiMetrics.GapMedium, vertical = UiMetrics.GapSmall))) {
                if (!own && !message.grouped) Text(message.senderName, inset.clickable(role = Role.Button) { onPerson(message.senderId) },
                    style = MaterialTheme.typography.labelLarge, color = fill.person(message.colorIndex), maxLines = 1, overflow = TextOverflow.Ellipsis)
                message.replyTo?.let { reply -> Box(inset) {
                    // A copy of a thread reply names its thread, and turns out an ordinary quote if its reply isn't in one.
                    var origin by remember(message.id) { mutableStateOf<ThreadOrigin?>(null) }
                    var notInThread by remember(message.id) { mutableStateOf(false) }
                    if (message.repliedToThread) LaunchedEffect(message.id, reply.eventId) {
                        origin = loadThreadOrigin(reply.eventId)
                        notInThread = origin == null
                    }
                    if (message.repliedToThread && !notInThread) ThreadCopyQuote(origin, onOpenThread)
                    else ReplyQuote(reply) { onOpenReply(reply.eventId) }
                } }
                val header = (!own && !message.grouped) || message.replyTo != null
                attachment?.let { Box(when {
                    !media -> Modifier.padding(vertical = UiMetrics.GapTiny)
                    header -> Modifier.padding(top = UiMetrics.GapTiny)
                    else -> Modifier
                }) {
                    Attachment(it, loadPicture, videos, opening, { onOpenFile(message) }, ::menu, onView)
                    if (media && body == null) Box(Modifier.align(Alignment.BottomEnd).padding(UiMetrics.GapSmall)
                        .background(fill.mediaShade, MaterialTheme.shapes.small).padding(horizontal = UiMetrics.GapTiny)) { time(fill.onMedia) }
                } }
                // Without a caption a file's time closes it, at its end.
                if (body != null) TimedBody(body, if (media) inset.padding(vertical = UiMetrics.GapTiny) else Modifier) { time(timeColor) }
                else if (!media) TimedBody(null, Modifier.align(Alignment.End)) { time(timeColor) }
                if (message.reactions.isNotEmpty()) Box(inset) {
                    Reactions(message.reactions, onReact?.let { react -> { key: String -> react(message, key) } }) { onShowReactions(message) }
                }
                val root = message.eventId
                // Inside a thread the root's replies bar says it instead.
                // A summary that lands after the row is on screen eases the bar in instead of popping it.
                AnimatedVisibility(message.thread != null && root != null && onOpenThread != null,
                    enter = expandVertically(Motion.pane()) + fadeIn(Motion.pane()), exit = ExitTransition.None) {
                    val thread = message.thread
                    if (thread != null && root != null && onOpenThread != null) Box(inset) { ThreadReplies(thread) { onOpenThread(root) } }
                }
            }
            // In the bubble's bottom padding, so the bar comes and goes without moving anything.
            message.uploadProgress?.let {
                Box(Modifier.matchParentSize().padding(start = UiMetrics.GapMedium, end = UiMetrics.GapMedium, bottom = UiMetrics.GapTiny),
                    contentAlignment = Alignment.BottomStart) {
                    LinearProgressIndicator({ it }, Modifier.fillMaxWidth().height(UiMetrics.GapTiny))
                }
            }
            }
        }
        if (own) OnAccentFill(bubble) else bubble()
    }
}

/**
 * A bubble's text with its time: beside a single line when there's room, as a messenger sets it, or else on a line of
 * its own at the end.
 */
@Composable
private fun TimedBody(body: (@Composable () -> Unit)?, modifier: Modifier = Modifier, time: @Composable () -> Unit) {
    Layout({ Box { body?.invoke() }; Box { time() } }, modifier) { (text, stamp), constraints ->
        val gap = UiMetrics.GapSmall.roundToPx()
        val loose = constraints.copy(minWidth = 0, minHeight = 0)
        val t = text.measure(loose)
        val m = stamp.measure(loose)
        val beside = t.width + gap + m.width <= constraints.maxWidth && t.height > 0
        val width = (if (beside) t.width + gap + m.width else maxOf(t.width, m.width)).coerceIn(constraints.minWidth, constraints.maxWidth)
        val height = if (beside) t.height else t.height + m.height
        layout(width, height) {
            t.placeRelative(0, 0)
            m.placeRelative(width - m.width, height - m.height)
        }
    }
}

/** Who is typing, in the header in place of its member line, as Telegram puts it; the header keeps its height. */
internal fun typingLabel(names: List<String>) = when (names.size) {
    1 -> "${names[0]} is typing…"
    2 -> "${names[0]} and ${names[1]} are typing…"
    else -> "Several people are typing…"
}
