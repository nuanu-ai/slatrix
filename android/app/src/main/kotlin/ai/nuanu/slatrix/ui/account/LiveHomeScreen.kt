package ai.nuanu.slatrix.ui.account

import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.foundation.layout.BoxWithConstraints
import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SpaceSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.core.WorkspaceMembership
import ai.nuanu.slatrix.core.WorkspaceRail
import ai.nuanu.slatrix.ui.designsystem.AvatarStyle
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.BottomSheet
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.glass
import ai.nuanu.slatrix.ui.designsystem.tabFit
import ai.nuanu.slatrix.ui.designsystem.glassSource
import ai.nuanu.slatrix.ui.designsystem.rememberGlass
import dev.chrisbanes.haze.HazeState
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import android.text.format.DateFormat
import android.text.format.DateUtils
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.*
import androidx.compose.animation.core.Animatable
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import ai.nuanu.slatrix.ui.designsystem.Motion
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.draw.shadow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.foundation.Image
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Calendar
import java.util.Date
import java.util.Locale

private enum class HomeTab(val label: String, val icon: ImageVector, val selectedIcon: ImageVector) {
    Home("Home", SlackIcons.Home, SlackIcons.HomeFilled),
    Dms("DMs", SlackIcons.Messages, SlackIcons.MessagesFilled),
    Later("Later", SlackIcons.Bookmark, SlackIcons.BookmarkFilled),
    Activity("Activity", SlackIcons.Bell, SlackIcons.BellFilled),
}

/** A page over Home, such as a conversation, kept by [key] while it stays in the stack. */
class WorkspaceCover(val key: Any, val content: @Composable () -> Unit)

private const val Home = "home"

/**
 * Home with [covers] over it, bottom to top. A page pushed over the one on top slides in over 140 ms with that page
 * drawn under it, so nothing blank shows; one that leaves goes at once, since predictive back has already played the
 * way out under the finger. Pages under the top stay composed, so going back finds one as it was, Home's tab, search
 * and scroll included, and the one right under the top draws, for a back swipe to show. Covered pages stop at
 * CREATED, as a backgrounded app's do, so they read no messages and take no Back. A page that leaves loses its state,
 * so a conversation opened again starts at its New line or its newest message, as Slack's does.
 */
@Composable
fun LiveWorkspace(covers: List<WorkspaceCover>, home: @Composable () -> Unit) {
    val saved = rememberSaveableStateHolder()
    val pages = listOf(WorkspaceCover(Home, home)) + covers
    val top = pages.last().key
    val shown = remember { object { var top: Any = Home; var keys = setOf<Any>(Home) } }
    // Pushed when the page that was on top stays, under it.
    val pushed = shown.top != top && pages.any { it.key == shown.top }
    val keys = pages.map { it.key }.toSet()
    (shown.keys - keys).forEach { saved.removeState(it.toString()) }
    shown.top = top
    shown.keys = keys
    val slide = remember(top) { Animatable(if (pushed) 0f else 1f) }
    LaunchedEffect(slide) { slide.animateTo(1f, Motion.pane()) }
    Box(Modifier.fillMaxSize()) {
        pages.forEachIndexed { index, page -> key(page.key) {
            val depth = pages.lastIndex - index
            val settled = slide.value == 1f
            Box(Modifier.fillMaxSize().then(when {
                depth == 0 -> Modifier.graphicsLayer {
                    alpha = slide.value
                    translationX = (1 - slide.value) * Motion.PushDistance * size.width
                }
                depth == 1 && !settled -> Modifier
                // Out of the accessibility tree, and drawn only right under the top.
                else -> Modifier.clearAndSetSemantics {}.graphicsLayer { if (depth > 1) alpha = 0f }
            // The top takes every touch, so none reaches a page under it.
            }).pointerInput(Unit) {}) {
                Covered(depth > 0) { saved.SaveableStateProvider(page.key.toString(), page.content) }
            }
        } }
    }
}

/** Holds [content]'s lifecycle at CREATED while [covered], and otherwise follows the screen's. */
@Composable
private fun Covered(covered: Boolean, content: @Composable () -> Unit) {
    val parent = LocalLifecycleOwner.current
    val cap = if (covered) Lifecycle.State.CREATED else Lifecycle.State.RESUMED
    val owner = remember(parent) { object : LifecycleOwner {
        override val lifecycle = LifecycleRegistry(this).apply { currentState = minOf(parent.lifecycle.currentState, cap) }
    } }
    DisposableEffect(parent, cap) {
        val follow = LifecycleEventObserver { _, _ -> owner.lifecycle.currentState = minOf(parent.lifecycle.currentState, cap) }
        parent.lifecycle.addObserver(follow)
        onDispose { parent.lifecycle.removeObserver(follow) }
    }
    DisposableEffect(owner) {
        onDispose { if (owner.lifecycle.currentState.isAtLeast(Lifecycle.State.CREATED)) owner.lifecycle.currentState = Lifecycle.State.DESTROYED }
    }
    CompositionLocalProvider(LocalLifecycleOwner provides owner, content = content)
}

@Composable
fun LiveHomeScreen(userId: String, state: RoomListState, onRoom: (String) -> Unit, onYou: () -> Unit, onRetry: () -> Unit,
    selectedSpaceId: String? = null, onSpace: (String?) -> Unit = {}, onStar: suspend (String, Boolean) -> Boolean = { _, _ -> true },
    onBrowseChannels: (() -> Unit)? = null, onCreateChannel: (() -> Unit)? = null,
    onInvitation: (String) -> Unit = {},
    /** Marks a conversation unread, or with false read. */
    onMarkUnread: suspend (String, Boolean) -> Boolean = { _, _ -> true },
    /** Marks these conversations read, and returns the ones that failed. */
    onMarkAllRead: suspend (List<String>) -> List<String> = { emptyList() },
    onNewMessage: (() -> Unit)? = null,
    /** Home's closed sections, kept with the account, and where a change to them goes. */
    collapsedSections: Set<String> = emptySet(), onCollapsedSections: (Set<String>) -> Unit = {},
    /** Search, opened from Home's search bar over the whole screen; it calls back to close. */
    search: @Composable (onClose: () -> Unit) -> Unit = {}, userAvatarUrl: String? = null, activity: @Composable () -> Unit = {},
    later: @Composable () -> Unit = {}) {
    // The tabs sit side by side, so a swipe moves between them as Telegram's folders do, and a tap slides there.
    val pager = rememberPagerState { HomeTab.entries.size }
    val tab = HomeTab.entries[pager.currentPage]
    var searching by rememberSaveable { mutableStateOf(false) }
    var actions by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var adding by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    // A star shows at once, as Slack's does, and holds until the account's tag catches up or the change fails.
    var starring by remember { mutableStateOf(emptyMap<String, Boolean>()) }
    // A read state shows at once too, until the room changes at all: the server's answer, or a message that came first.
    var marking by remember { mutableStateOf(emptyMap<String, Pair<Boolean, RoomSummary>>()) }
    LaunchedEffect(state.rooms) {
        starring = starring.filter { (id, starred) -> state.rooms.none { it.id == id && it.starred == starred } }
        marking = marking.filter { (id, marked) -> state.rooms.any { it.id == id && it == marked.second } }
    }
    val shown = remember(state, starring, marking) {
        if (starring.isEmpty() && marking.isEmpty()) state
        else state.copy(rooms = state.rooms.map { room ->
            val starred = starring[room.id]?.let { room.copy(starred = it) } ?: room
            when (marking[room.id]?.first) {
                true -> if (starred.unread == UnreadBadge.None) starred.copy(unread = UnreadBadge.Bold) else starred
                false -> starred.copy(unread = UnreadBadge.None)
                null -> starred
            }
        })
    }
    fun mark(ids: Collection<String>, unread: Boolean) {
        marking = marking + state.rooms.filter { it.id in ids }.associate { it.id to (unread to it) }
    }
    val homeList = rememberLazyListState()
    val directList = rememberLazyListState()
    val colors = SlatrixTheme.colors
    BackHandler(enabled = searching) { searching = false }
    BackHandler(enabled = tab != HomeTab.Home && !searching) { scope.launch { pager.animateScrollToPage(HomeTab.Home.ordinal) } }
    if (searching) {
        Box(Modifier.fillMaxSize().background(colors.canvas)) { search { searching = false } }
        return
    }
    val glass = rememberGlass()
    // New message sits beside the capsule while every tab still fits its widest label with room a side; on a narrow
    // phone or at a large font the capsule takes the width and New message rises above it.
    val measurer = rememberTextMeasurer()
    val label = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold)
    val density = LocalDensity.current
    val widest = remember(measurer, label, density) {
        with(density) { HomeTab.entries.maxOf { measurer.measure(it.label, label).size.width }.toDp() }
    }
    BoxWithConstraints(Modifier.fillMaxSize().background(colors.canvas)) {
        val beside = onNewMessage == null ||
            (maxWidth - UiMetrics.GapLarge * 2 - UiMetrics.Fab - UiMetrics.GapMedium - UiMetrics.TabInset * 2) / HomeTab.entries.size >=
            widest + UiMetrics.GapMedium * 2
        // The lists scroll on under the tab capsule, and end clear of it and of New message above it.
        val clearance = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + UiMetrics.TabBar + UiMetrics.GapSmall * 2 +
            (UiMetrics.Fab + UiMetrics.GapLarge) * (if (beside) 0 else 1)
        // Each tab owns its title, which slides with it under the finger rather than swap halfway.
        HorizontalPager(pager, Modifier.fillMaxSize().glassSource(glass), key = { HomeTab.entries[it] }) { page ->
            val pageTab = HomeTab.entries[page]
            Column(Modifier.fillMaxSize()) {
                HomeHeader(pageTab, userId, userAvatarUrl, state, selectedSpaceId, onSpace, onYou)
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    when (pageTab) {
                        HomeTab.Home -> HomeList(homeList, shown, selectedSpaceId, onRoom,
                            (onBrowseChannels ?: onCreateChannel)?.let { { adding = true } }, onInvitation, clearance, collapsedSections,
                            onCollapsedSections, { actions = it.id }) {
                            HomeSearchBar(state.spaces.firstOrNull { it.id == selectedSpaceId }?.name) { searching = true }
                        }
                        HomeTab.Dms -> DirectList(directList, shown, onRoom, clearance) { actions = it.id }
                        HomeTab.Activity -> Box(Modifier.padding(bottom = clearance)) { activity() }
                        HomeTab.Later -> Box(Modifier.padding(bottom = clearance)) { later() }
                    }
                    OfflineBanner()
                }
            }
        }
        val newMessage = @Composable {
            // Slack's new message button, round beside the capsule or above it.
            if (onNewMessage != null) Box(Modifier.size(UiMetrics.Fab)
                .shadow(UiMetrics.GapSmall, CircleShape, ambientColor = colors.accentFill, spotColor = colors.accentFill)
                .clip(CircleShape).background(colors.accentFill).clickable(role = Role.Button, onClick = onNewMessage)
                .semantics { contentDescription = "New message" }, contentAlignment = Alignment.Center) {
                Icon(SlackIcons.Compose, null, Modifier.size(UiMetrics.LargeIcon), tint = colors.onAccent)
            }
        }
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding()
            .padding(start = UiMetrics.GapLarge, end = UiMetrics.GapLarge, bottom = UiMetrics.GapSmall),
            horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
            if (!beside) newMessage()
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
                TabCapsule(glass, tab, { pager.currentPage + pager.currentPageOffsetFraction }, Modifier.weight(1f)) {
                    scope.launch { pager.animateScrollToPage(it.ordinal) }
                }
                if (beside) newMessage()
            }
        }
        val failure = notice
        val snackbar = Modifier.align(Alignment.BottomCenter).padding(bottom = clearance).padding(UiMetrics.GapLarge)
        if (failure != null) {
            Snackbar(snackbar.semantics { liveRegion = LiveRegionMode.Polite }) { Text(failure) }
        } else state.error?.let { message ->
            Snackbar(snackbar, action = { TextButton(onClick = onRetry) { Text("Retry") } }) { Text(message) }
        }
    }
    // Looked up on each change, so the sheet follows the room's live name and star, and closes if the room goes.
    shown.rooms.firstOrNull { it.id == actions }?.let { room ->
        // Every unread conversation in view: the open workspace's and the direct messages, as Slack's workspace holds them.
        val unreadIds = shown.rooms.filter {
            it.unread != UnreadBadge.None && WorkspaceMembership.includes(it.direct, it.spaceIds, selectedSpaceId)
        }.map { it.id }
        ConversationActions(room, unreadIds.isNotEmpty(), { starred ->
            starring = starring + (room.id to starred)
            scope.launch {
                if (!onStar(room.id, starred)) {
                    starring = starring - room.id
                    notice = if (starred) "Couldn’t star ${room.name}." else "Couldn’t unstar ${room.name}."
                }
            }
        }, { unread ->
            mark(listOf(room.id), unread)
            scope.launch {
                if (!onMarkUnread(room.id, unread)) {
                    marking = marking - room.id
                    notice = if (unread) "Couldn’t mark ${room.name} unread." else "Couldn’t mark ${room.name} as read."
                }
            }
        }, {
            mark(unreadIds, false)
            scope.launch {
                val failed = onMarkAllRead(unreadIds)
                if (failed.isNotEmpty()) {
                    marking = marking - failed.toSet()
                    notice = "Couldn’t mark everything as read."
                }
            }
        }) { actions = null }
    }
    if (adding) AddChannelSheet(onBrowseChannels, onCreateChannel) { adding = false }
    notice?.let { LaunchedEffect(it) { delay(UiMetrics.NoticeMillis); notice = null } }
}

/** Design B's tab bar: a capsule of frosted glass floating over the list, the open tab on an accent tint. */
@Composable
private fun TabCapsule(glass: HazeState, tab: HomeTab, position: () -> Float, modifier: Modifier, onTab: (HomeTab) -> Unit) {
    val colors = SlatrixTheme.colors
    Row(modifier.heightIn(min = UiMetrics.TabBar).glass(glass, colors.glass, CircleShape, lifted = true)
        .padding(UiMetrics.TabInset).selectableGroup()
        // The open tab's tint follows the pager under the finger, read while drawing, so a swipe never recomposes the bar.
        .drawBehind {
            val width = size.width / HomeTab.entries.size
            drawRoundRect(colors.accentTint, Offset(width * position(), 0f), Size(width, size.height), CornerRadius(size.height / 2))
        }) {
        HomeTab.entries.forEach { destination ->
            val selected = tab == destination
            val tint = if (selected) colors.accent else colors.textSecondary
            Column(Modifier.weight(1f).heightIn(min = UiMetrics.TabBar - UiMetrics.TabInset * 2).clip(CircleShape)
                .selectable(selected, role = Role.Tab) { onTab(destination) },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Icon(if (selected) destination.selectedIcon else destination.icon, null, Modifier.size(UiMetrics.LargeIcon), tint = tint)
                // A label too long for its tab at a large font shrinks rather than lose its end to the tab's round side.
                Text(destination.label, Modifier.padding(horizontal = UiMetrics.GapSmall), style = MaterialTheme.typography.labelSmall,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium, color = tint, maxLines = 1,
                    autoSize = MaterialTheme.typography.tabFit)
            }
        }
    }
}

/** Material's search bar, which opens search over Home. */
@Composable
private fun HomeSearchBar(space: String?, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    Row(Modifier.padding(start = UiMetrics.GapLarge, end = UiMetrics.GapLarge, bottom = UiMetrics.GapSmall).fillMaxWidth()
        .heightIn(min = UiMetrics.SearchBar).clip(CircleShape).background(colors.raised).clickable(role = Role.Button, onClick = onClick)
        .padding(horizontal = UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        Icon(SlackIcons.Search, null, Modifier.size(UiMetrics.LargeIcon), tint = colors.textSecondary)
        Text(space?.let { "Search $it" } ?: "Search", style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun HomeHeader(tab: HomeTab, userId: String, userAvatarUrl: String?, state: RoomListState, selectedSpaceId: String?, onSpace: (String?) -> Unit, onYou: () -> Unit) {
    var switching by remember { mutableStateOf(false) }
    // The avatar's touch target overhangs its picture, so the end gutter is smaller and the picture lines up with the list.
    Row(Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = UiMetrics.HeaderRow)
        .padding(start = UiMetrics.GapLarge, end = UiMetrics.GapTiny), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f)) {
            when (tab) {
                HomeTab.Home -> {
                    val space = state.spaces.firstOrNull { it.id == selectedSpaceId }
                    Row(Modifier.heightIn(min = UiMetrics.Touch).clickable(role = Role.Button) { switching = true }
                        .semantics { contentDescription = "Switch workspace" }, verticalAlignment = Alignment.CenterVertically) {
                        // A saved workspace whose space hasn't loaded yet keeps its place blank rather than say All.
                        val loading = space == null && selectedSpaceId != null
                        WorkspaceIcon(space, UiMetrics.HeaderAvatar, loading)
                        Spacer(Modifier.width(UiMetrics.GapMedium))
                        HeaderTitle(space?.name ?: if (loading) "" else "All conversations", Modifier.weight(1f, fill = false))
                        Spacer(Modifier.width(UiMetrics.GapSmall))
                        Icon(SlackIcons.ChevronDown, null, Modifier.size(UiMetrics.Icon), tint = SlatrixTheme.colors.textSecondary)
                    }
                }
                HomeTab.Dms -> HeaderTitle("Direct messages")
                HomeTab.Activity -> HeaderTitle("Activity")
                HomeTab.Later -> HeaderTitle("Later")
            }
        }
        Box(Modifier.sizeIn(minWidth = UiMetrics.Touch, minHeight = UiMetrics.Touch)
            .clickable(role = Role.Button, onClick = onYou).semantics { contentDescription = "You" }, contentAlignment = Alignment.Center) {
            LiveAvatar(AvatarPlaceholder.initials(userId.removePrefix("@").substringBefore(':')), AvatarPlaceholder.colorIndex(userId),
                UiMetrics.HeaderAvatar, userAvatarUrl)
        }
    }
    if (switching) WorkspaceSwitcher(state, selectedSpaceId, onSpace) { switching = false }
}

/** Slack's workspace switcher: each workspace's icon and name, the open one checked. */
@Composable
private fun WorkspaceSwitcher(state: RoomListState, selectedSpaceId: String?, onSpace: (String?) -> Unit, onDismiss: () -> Unit) {
    val entries = remember(state.spaces, state.rooms) { WorkspaceRail.entries(state.spaces, state.rooms) }
    BottomSheet(onDismissRequest = onDismiss, containerColor = SlatrixTheme.colors.overlay) {
        Column(Modifier.fillMaxWidth().padding(bottom = UiMetrics.GapLarge)) {
            Text("Workspaces", Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
                style = MaterialTheme.typography.titleMedium)
            for (space in entries) {
                val selected = space?.id == selectedSpaceId
                Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.WorkspaceRow)
                    .selectable(selected, role = Role.RadioButton) {
                        onSpace(space?.id)
                        onDismiss()
                    }.padding(horizontal = UiMetrics.GapLarge),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
                    WorkspaceIcon(space, UiMetrics.ChannelTile)
                    Text(space?.name ?: "All conversations", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
                        fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (selected) Icon(SlackIcons.Check, null, Modifier.size(UiMetrics.LargeIcon), tint = SlatrixTheme.colors.accent)
                }
            }
        }
    }
}

/** A workspace's rounded-square icon: its initials on its own color, or a tray for All conversations. */
@Composable
private fun WorkspaceIcon(space: SpaceSummary?, size: Dp, loading: Boolean = false) {
    val colors = SlatrixTheme.colors
    Box(Modifier.size(size).clip(MaterialTheme.shapes.medium)
        .background(if (space != null) DesignTokens.avatarColors[space.colorIndex] else colors.accentTint), contentAlignment = Alignment.Center) {
        if (space == null && !loading) Icon(SlackIcons.Tray, null, Modifier.size(UiMetrics.Icon), tint = colors.accent)
        else if (space != null) Text(space.initials, Modifier.padding(horizontal = UiMetrics.GapTiny), style = AvatarStyle.label,
            color = colors.onAvatar, maxLines = 1, softWrap = false, autoSize = AvatarStyle.fit)
        Picture(space?.avatarUrl, size)
    }
}

@Composable
private fun HeaderTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier, style = MaterialTheme.typography.titleLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
}

private enum class HomeSection(val label: String) {
    Starred("Starred"),
    Channels("Channels"),
    Direct("Direct messages"),
}

@Composable
private fun HomeList(list: LazyListState, state: RoomListState, selectedSpaceId: String?, onRoom: (String) -> Unit,
    onAddChannel: (() -> Unit)?, onInvitation: (String) -> Unit, bottom: Dp, saved: Set<String>, onSaved: (Set<String>) -> Unit,
    onActions: (RoomSummary) -> Unit, search: @Composable () -> Unit) {
    // A saved workspace's channels are known only with its spaces, so its list waits for them rather than filling in.
    val waiting = state.loading || (selectedSpaceId != null && !state.spacesKnown)
    val sections = remember(state.rooms, selectedSpaceId) {
        val visible = state.rooms.filter { WorkspaceMembership.includes(it.direct, it.spaceIds, selectedSpaceId) }
        // Slack drops Starred while nothing is starred, but always shows where channels and messages go.
        listOfNotNull(
            visible.filter { it.starred }.takeIf { it.isNotEmpty() }?.let { HomeSection.Starred to it },
            HomeSection.Channels to visible.filter { !it.starred && !it.direct },
            HomeSection.Direct to visible.filter { !it.starred && it.direct },
        )
    }
    var collapsed by remember(saved) { mutableStateOf(saved) }
    LazyColumn(Modifier.fillMaxSize(), list, contentPadding = PaddingValues(bottom = bottom)) {
        // The first row, so it scrolls away under the header with the list, as Telegram's does.
        item(key = "search") { search() }
        if (waiting) {
            item { ConnectionIndicator(true, null) }
        } else {
            // Invitations lead while there are any, all of them in view, as unread conversations stay.
            if (state.invitations.isNotEmpty()) {
                item(key = "invitations") { InvitationsHeader() }
                items(state.invitations, key = { "invitation ${it.id}" }) { InvitationRow(it, onInvitation) }
            }
            sections.forEach { (section, rooms) ->
                val open = section.name !in collapsed
                item(key = section.name) {
                    SectionHeader(section, open) {
                        collapsed = if (open) collapsed + section.name else collapsed - section.name
                        onSaved(collapsed)
                    }
                }
                // A collapsed section keeps its unread conversations in view, as Slack's does.
                items(if (open) rooms else rooms.filter { it.unread != UnreadBadge.None }, key = { it.id }) {
                    CompactRow(it, onRoom, onActions)
                }
                if (open && section == HomeSection.Channels && onAddChannel != null) item(key = "add-channel") { AddChannelRow(onAddChannel) }
            }
        }
    }
}

/**
 * Slack's section header: its title in semibold at the list's edge, ahead of the rows' marks, then a chevron, with room
 * above, so it reads as a heading over its rows rather than one of them. It opens and closes.
 */
@Composable
private fun SectionHeader(section: HomeSection, open: Boolean, onToggle: () -> Unit) {
    val colors = SlatrixTheme.colors
    Row(Modifier.padding(top = UiMetrics.GapMedium).fillMaxWidth().heightIn(min = UiMetrics.SectionHeader)
        .clickable(role = Role.Button, onClickLabel = if (open) "Collapse" else "Expand", onClick = onToggle)
        .semantics(mergeDescendants = true) { stateDescription = if (open) "Expanded" else "Collapsed" }
        .padding(horizontal = UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
        Text(section.label, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
            color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Icon(if (open) SlackIcons.ChevronDown else SlackIcons.ChevronRight, null, Modifier.size(UiMetrics.SmallIcon), tint = colors.textSecondary)
    }
}

/** Slack's Add channel row, closing the Channels section, its plus where a channel's # sits. */
@Composable
private fun AddChannelRow(onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.CompactRow).clickable(role = Role.Button, onClick = onClick)
        .padding(horizontal = UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        Lead { Icon(SlackIcons.Plus, null, Modifier.size(glyph()), tint = colors.textSecondary) }
        Text("Add channel", style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary, maxLines = 1,
            overflow = TextOverflow.Ellipsis)
    }
}

/** The narrow column ahead of a row's name: a channel's #, a person's picture or a section's arrow. */
@Composable
internal fun Lead(content: @Composable () -> Unit) {
    Box(Modifier.widthIn(min = leadSize()), contentAlignment = Alignment.Center) { content() }
}

/** A row's # or arrow, at the size of its text, so it grows with the phone's font. */
@Composable
internal fun glyph(): Dp = with(LocalDensity.current) { MaterialTheme.typography.bodyLarge.fontSize.toDp() * GlyphScale }

/** Slack's Home row: one line, a channel's # or a person's picture, the name in bold while unread, and a mention count. */
@Composable
private fun CompactRow(room: RoomSummary, onRoom: (String) -> Unit, onActions: (RoomSummary) -> Unit) {
    val colors = SlatrixTheme.colors
    val unread = room.unread != UnreadBadge.None
    val color = if (unread) colors.textPrimary else colors.textSecondary
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.CompactRow).conversation(room, onRoom, onActions).unreadState(room)
        .padding(horizontal = UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        Lead {
            if (room.direct) LiveAvatar(room.initials, room.colorIndex, leadSize(), room.avatarUrl)
            else ChannelGlyph(room.isPrivate, color)
        }
        Text(room.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = color,
            fontWeight = if (unread) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis)
        UnreadCount(room.unread)
    }
}

/** A channel's plain # or, for a private one, its lock, in [color]. */
@Composable
internal fun ChannelGlyph(private: Boolean, color: Color) {
    Icon(if (private) SlackIcons.Lock else SlackIcons.Hash, if (private) "Private channel" else null, Modifier.size(glyph()), tint = color)
}

/** A person's picture in the same column, so it grows with the font as the # beside it does. */
@Composable
internal fun leadSize(): Dp = with(LocalDensity.current) { MaterialTheme.typography.bodyLarge.fontSize.toDp() * LeadScale }

/** A 20 sp mark and a 24 sp picture beside 16 sp text, as the boards draw them. */
private const val GlyphScale = 1.25f
private const val LeadScale = 1.5f

@Composable
private fun DirectList(list: LazyListState, state: RoomListState, onRoom: (String) -> Unit, bottom: Dp, onActions: (RoomSummary) -> Unit) {
    val direct = remember(state.rooms) { state.rooms.filter { it.direct } }
    LazyColumn(Modifier.fillMaxSize(), list, contentPadding = PaddingValues(bottom = bottom)) {
        if (state.loading) item { ConnectionIndicator(true, null) }
        items(direct, key = { it.id }) { ConversationRow(it, onRoom, onActions) }
        if (!state.loading && direct.isEmpty()) item { EmptyList("No direct messages") }
    }
}

@Composable
private fun EmptyList(text: String) {
    Text(text, Modifier.padding(UiMetrics.GapLarge), style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textSecondary)
}

/** Opens a conversation on tap and its actions on a long press, as Slack's rows do. */
@OptIn(ExperimentalFoundationApi::class)
private fun Modifier.conversation(room: RoomSummary, onRoom: (String) -> Unit, onActions: (RoomSummary) -> Unit) =
    combinedClickable(role = Role.Button, onLongClickLabel = "More actions", onLongClick = { onActions(room) }) { onRoom(room.id) }

/**
 * The DMs tab's two-line row: the person's picture, the name in bold while unread, and under it the newest message and
 * the unread count; when it came sits at the end of the name's line.
 */
@Composable
private fun ConversationRow(room: RoomSummary, onRoom: (String) -> Unit, onActions: (RoomSummary) -> Unit) {
    val colors = SlatrixTheme.colors
    val unread = room.unread != UnreadBadge.None
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.ConversationRow).conversation(room, onRoom, onActions).unreadState(room)
        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        LiveAvatar(room.initials, room.colorIndex, UiMetrics.RowAvatar, room.avatarUrl)
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                Text(room.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
                    fontWeight = if (unread) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis)
                room.latest?.let {
                    Text(latestTime(it.timestamp), style = MaterialTheme.typography.labelMedium,
                        color = if (room.unread is UnreadBadge.Count) colors.accent else colors.textSecondary, maxLines = 1)
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                // Held at a line's height while there's nothing to show, so every row is the same height.
                Text(preview(room), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary,
                    minLines = 1, maxLines = 1, overflow = TextOverflow.Ellipsis)
                UnreadCount(room.unread)
            }
        }
    }
}

/** The newest message under a row's name, yours after You. */
@Composable
private fun preview(room: RoomSummary): AnnotatedString {
    val latest = room.latest ?: return AnnotatedString("")
    val body = latest.body ?: return AnnotatedString("")
    val color = SlatrixTheme.colors.textPrimary
    return remember(latest.own, body, color) {
        buildAnnotatedString {
            if (latest.own) withStyle(SpanStyle(color = color)) { append("You: ") }
            append(body)
        }
    }
}

/** Slack's long-press sheet for a conversation: its name, then what can be done with it. */
@Composable
private fun ConversationActions(room: RoomSummary, anyUnread: Boolean, onStar: (Boolean) -> Unit, onMarkUnread: (Boolean) -> Unit,
    onMarkAllRead: () -> Unit, onDismiss: () -> Unit) {
    val noun = if (room.direct) "conversation" else "channel"
    // The sheet closes at once, so an action applies as it goes.
    fun afterHiding(action: () -> Unit) { action(); onDismiss() }
    BottomSheet(onDismissRequest = onDismiss, containerColor = SlatrixTheme.colors.overlay) {
        Column(Modifier.fillMaxWidth().padding(bottom = UiMetrics.GapLarge)) {
            Text(room.name, Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
                style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val starred = room.starred
            SheetRow(if (starred) SlackIcons.StarFilled else SlackIcons.Star, if (starred) "Unstar $noun" else "Star $noun") {
                afterHiding { onStar(!starred) }
            }
            val unread = room.unread != UnreadBadge.None
            SheetRow(if (unread) SlackIcons.MarkRead else SlackIcons.MarkUnread, if (unread) "Mark as read" else "Mark unread") {
                afterHiding { onMarkUnread(!unread) }
            }
            if (anyUnread) SheetRow(SlackIcons.MarkAllRead, "Mark all as read") { afterHiding(onMarkAllRead) }
        }
    }
}

@Composable
private fun SheetRow(icon: ImageVector, label: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(role = Role.Button, onClick = onClick)
        .padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(UiMetrics.Icon))
        Text(label, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun UnreadCount(unread: UnreadBadge) {
    if (unread !is UnreadBadge.Count) return
    val colors = SlatrixTheme.colors
    Box(Modifier.heightIn(min = UiMetrics.Badge).widthIn(min = UiMetrics.Badge).clip(CircleShape).background(colors.mention)
        .padding(horizontal = UiMetrics.GapTiny * 1.5f), contentAlignment = Alignment.Center) {
        Text(unread.label, style = MaterialTheme.typography.labelSmall, color = colors.onAccent, maxLines = 1)
    }
}

private fun Modifier.unreadState(room: RoomSummary): Modifier {
    val description = when (val unread = room.unread) {
        UnreadBadge.None -> return this
        UnreadBadge.Bold -> "Unread"
        is UnreadBadge.Count -> when {
            room.direct && unread.label == "1" -> "1 unread message"
            room.direct -> "${unread.label} unread messages"
            unread.label == "1" -> "1 mention"
            else -> "${unread.label} mentions"
        }
    }
    return semantics { stateDescription = description }
}

@Composable
internal fun latestTime(timestamp: Long): String {
    val locale = LocalConfiguration.current.locales[0]
    return remember(timestamp, locale) {
        val date = Date(timestamp)
        val thisYear = Calendar.getInstance().get(Calendar.YEAR) == Calendar.getInstance().apply { time = date }.get(Calendar.YEAR)
        when {
            DateUtils.isToday(timestamp) -> java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT, locale).format(date)
            else -> java.text.SimpleDateFormat(DateFormat.getBestDateTimePattern(locale, if (thisYear) "MMMd" else "yMMMd"), locale).format(date)
        }
    }
}

@Composable
internal fun LiveAvatar(initials: String, colorIndex: Int, size: Dp = UiMetrics.Avatar, url: String? = null) {
    // People are round, as in every messenger; workspaces and channels are rounded squares.
    Box(Modifier.size(size).clip(CircleShape).background(DesignTokens.avatarColors[colorIndex]), contentAlignment = Alignment.Center) {
        // Two letters shrink to fit, so every avatar in a list has the same width.
        Text(initials, Modifier.padding(horizontal = UiMetrics.GapTiny), style = AvatarStyle.label, color = SlatrixTheme.colors.onAvatar,
            maxLines = 1, softWrap = false, autoSize = AvatarStyle.fit)
        Picture(url, size)
    }
}

/** The picture at [url] over whatever sits beneath it, once it has loaded, in the same box, so nothing moves. */
@Composable
private fun Picture(url: String?, size: Dp) {
    rememberAvatar(url, size)?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
}
