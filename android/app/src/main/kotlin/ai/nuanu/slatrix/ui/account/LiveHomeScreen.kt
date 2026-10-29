package ai.nuanu.slatrix.ui.account

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
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.StatusBarOverWorkspaceBar
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
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.Image
import androidx.compose.ui.layout.ContentScale
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
    Activity("Activity", SlackIcons.Bell, SlackIcons.BellFilled),
    Search("Search", SlackIcons.Search, SlackIcons.SearchSelected),
}

/** Shows [cover], such as a conversation, in Home's place, and gives Home back its tab, search and scroll position after. */
@Composable
fun LiveWorkspace(cover: (@Composable () -> Unit)?, home: @Composable () -> Unit) {
    val saved = rememberSaveableStateHolder()
    if (cover != null) cover() else saved.SaveableStateProvider("home", home)
}

@Composable
fun LiveHomeScreen(userId: String, state: RoomListState, onRoom: (String) -> Unit, onYou: () -> Unit, onRetry: () -> Unit,
    selectedSpaceId: String? = null, onSpace: (String?) -> Unit = {}, onStar: suspend (String, Boolean) -> Boolean = { _, _ -> true },
    onBrowseChannels: (() -> Unit)? = null, onCreateChannel: (() -> Unit)? = null,
    /** Marks a conversation unread, or with false read. */
    onMarkUnread: suspend (String, Boolean) -> Boolean = { _, _ -> true },
    /** Marks these conversations read, and returns the ones that failed. */
    onMarkAllRead: suspend (List<String>) -> List<String> = { emptyList() },
    /** How many messages wait in Later, for its card at the top of Home; null leaves the card out. */
    laterCount: Int? = null, onLater: () -> Unit = {},
    search: @Composable () -> Unit = {}, userAvatarUrl: String? = null, activity: @Composable () -> Unit = {}) {
    var tab by rememberSaveable { mutableStateOf(HomeTab.Home) }
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
    BackHandler(enabled = tab != HomeTab.Home) { tab = HomeTab.Home }
    StatusBarOverWorkspaceBar()
    BoxWithConstraints(Modifier.fillMaxSize().background(colors.workspaceBar)) {
        val expanded = maxWidth >= UiMetrics.ExpandedWidth
        Row(Modifier.fillMaxSize()) {
            if (expanded) {
                NavigationRail(containerColor = colors.raised) {
                    val navigationColors = NavigationRailItemDefaults.colors(
                        selectedIconColor = colors.textPrimary, selectedTextColor = colors.textPrimary,
                        indicatorColor = colors.selection, unselectedIconColor = colors.textSecondary,
                        unselectedTextColor = colors.textSecondary,
                    )
                    HomeTab.entries.forEach { destination ->
                        NavigationRailItem(selected = tab == destination, onClick = { tab = destination },
                            icon = { Icon(if (tab == destination) destination.selectedIcon else destination.icon, null) },
                            label = { Text(destination.label) }, colors = navigationColors)
                    }
                }
            }
            Column(Modifier.weight(1f)) {
                HomeHeader(tab, userId, userAvatarUrl, state, selectedSpaceId, onSpace, onYou)
                Surface(Modifier.weight(1f).fillMaxWidth(), shape = SlatrixTheme.topPanelShape, color = colors.canvas) {
                    Box(Modifier.fillMaxSize()) {
                        when (tab) {
                            HomeTab.Home -> HomeList(homeList, shown, selectedSpaceId, onRoom, onBrowseChannels,
                                (onBrowseChannels ?: onCreateChannel)?.let { { adding = true } },
                                laterCount?.let { count -> { LaterCard(count, onLater) } }) { actions = it.id }
                            HomeTab.Dms -> DirectList(directList, shown, onRoom) { actions = it.id }
                            HomeTab.Activity -> activity()
                            HomeTab.Search -> search()
                        }
                        val failure = notice
                        if (failure != null) {
                            Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge)
                                .semantics { liveRegion = LiveRegionMode.Polite }) { Text(failure) }
                        } else state.error?.let { message ->
                            Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge),
                                action = { TextButton(onClick = onRetry) { Text("Retry") } }) { Text(message) }
                        }
                    }
                }
                if (!expanded) {
                    HorizontalDivider(color = colors.border)
                    NavigationBar(containerColor = colors.raised) {
                        val navigationColors = NavigationBarItemDefaults.colors(
                            selectedIconColor = colors.textPrimary, selectedTextColor = colors.textPrimary, indicatorColor = colors.pressed,
                            unselectedIconColor = colors.textSecondary, unselectedTextColor = colors.textSecondary,
                        )
                        HomeTab.entries.forEach { destination ->
                            val selected = tab == destination
                            NavigationBarItem(selected = selected, onClick = { tab = destination },
                                icon = { Icon(if (selected) destination.selectedIcon else destination.icon, null) },
                                label = { Text(destination.label, fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal) },
                                colors = navigationColors)
                        }
                    }
                }
            }
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

@Composable
private fun HomeHeader(tab: HomeTab, userId: String, userAvatarUrl: String?, state: RoomListState, selectedSpaceId: String?, onSpace: (String?) -> Unit, onYou: () -> Unit) {
    var switching by remember { mutableStateOf(false) }
    CompositionLocalProvider(LocalContentColor provides SlatrixTheme.colors.onAccent) {
        // The avatar's touch target overhangs its tile, so the end gutter is smaller and the tile lines up with Slack's.
        Row(Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = UiMetrics.RootHeaderHeight)
            .padding(start = UiMetrics.GapLarge, end = UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
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
                            Icon(SlackIcons.ChevronDown, null, Modifier.size(UiMetrics.Icon))
                        }
                    }
                    HomeTab.Dms -> HeaderTitle("Direct messages")
                    HomeTab.Activity -> HeaderTitle("Activity")
                    HomeTab.Search -> HeaderTitle("Search")
                }
            }
            Box(Modifier.sizeIn(minWidth = UiMetrics.Touch, minHeight = UiMetrics.Touch)
                .clickable(role = Role.Button, onClick = onYou).semantics { contentDescription = "You" }, contentAlignment = Alignment.Center) {
                LiveAvatar(AvatarPlaceholder.initials(userId.removePrefix("@").substringBefore(':')), AvatarPlaceholder.colorIndex(userId),
                    UiMetrics.HeaderAvatar, userAvatarUrl)
            }
        }
    }
    if (switching) WorkspaceSwitcher(state, selectedSpaceId, onSpace) { switching = false }
}

/** Slack's workspace switcher: each workspace's icon and name, the open one checked. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WorkspaceSwitcher(state: RoomListState, selectedSpaceId: String?, onSpace: (String?) -> Unit, onDismiss: () -> Unit) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val entries = remember(state.spaces, state.rooms) { WorkspaceRail.entries(state.spaces, state.rooms) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet, shape = SlatrixTheme.topPanelShape,
        containerColor = SlatrixTheme.colors.overlay) {
        Column(Modifier.fillMaxWidth().padding(bottom = UiMetrics.GapLarge)) {
            Text("Workspaces", Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
                style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
            for (space in entries) {
                val selected = space?.id == selectedSpaceId
                Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.WorkspaceRow)
                    .selectable(selected, role = Role.RadioButton) {
                        onSpace(space?.id)
                        scope.launch { sheet.hide() }.invokeOnCompletion { onDismiss() }
                    }.padding(horizontal = UiMetrics.GapLarge),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
                    WorkspaceIcon(space, UiMetrics.ListAvatar)
                    Text(space?.name ?: "All conversations", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
                        fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (selected) Icon(SlackIcons.Check, null, Modifier.size(UiMetrics.LargeIcon))
                }
            }
        }
    }
}

/** A workspace's rounded-square icon: its initials on the palette's color, or a tray for All conversations. */
@Composable
private fun WorkspaceIcon(space: SpaceSummary?, size: Dp, loading: Boolean = false) {
    Box(Modifier.size(size).clip(MaterialTheme.shapes.large).background(SlatrixTheme.colors.selectionStrong),
        contentAlignment = Alignment.Center) {
        if (space == null && !loading) Icon(SlackIcons.Tray, null, Modifier.size(UiMetrics.Icon), tint = SlatrixTheme.colors.onAccent)
        else if (space != null) Text(space.initials, Modifier.padding(horizontal = UiMetrics.GapTiny), style = AvatarStyle.label,
            color = SlatrixTheme.colors.onAccent, maxLines = 1, softWrap = false, autoSize = AvatarStyle.fit)
        Picture(space?.avatarUrl, size)
    }
}

@Composable
private fun HeaderTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Black,
        maxLines = 1, overflow = TextOverflow.Ellipsis)
}

private enum class HomeSection(val label: String, val icon: ImageVector) {
    Starred("Starred", SlackIcons.Star),
    Channels("Channels", SlackIcons.Hash),
    Direct("Direct messages", SlackIcons.Messages),
}

@Composable
private fun HomeList(list: LazyListState, state: RoomListState, selectedSpaceId: String?, onRoom: (String) -> Unit,
    onBrowseChannels: (() -> Unit)?, onAddChannel: (() -> Unit)?, cards: (@Composable () -> Unit)?, onActions: (RoomSummary) -> Unit) {
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
    var collapsed by rememberSaveable { mutableStateOf(emptyList<String>()) }
    LazyColumn(Modifier.fillMaxSize(), list, contentPadding = PaddingValues(vertical = UiMetrics.GapSmall)) {
        // Slack's cards above the sections; they're kept on this device, so they show while the list loads.
        if (cards != null) item(key = "cards") {
            Column {
                Row(Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall)) { cards() }
                SectionDivider()
            }
        }
        if (waiting) {
            item { ConnectionIndicator(true, null) }
        } else {
            sections.forEachIndexed { index, (section, rooms) ->
                if (index > 0) item(key = "divider-${section.name}") { SectionDivider() }
                val open = section.name !in collapsed
                item(key = section.name) {
                    SectionHeader(section, open, onBrowseChannels.takeIf { section == HomeSection.Channels }) {
                        collapsed = if (open) collapsed + section.name else collapsed - section.name
                    }
                }
                // A collapsed section keeps its unread conversations in view, as Slack's does.
                items(if (open) rooms else rooms.filter { it.unread != UnreadBadge.None }, key = { it.id }) {
                    LiveRoomRow(it, onRoom, onActions)
                }
                if (open && section == HomeSection.Channels && onAddChannel != null) item(key = "add-channel") { AddChannelRow(onAddChannel) }
            }
        }
    }
}

@Composable
private fun SectionHeader(section: HomeSection, open: Boolean, onOpen: (() -> Unit)?, onToggle: () -> Unit) {
    val toggle = Modifier.clickable(role = Role.Button, onClickLabel = if (open) "Collapse" else "Expand", onClick = onToggle)
        .semantics(mergeDescendants = true) { stateDescription = if (open) "Expanded" else "Collapsed" }
    // A section that opens something, as Slack's Channels › does, leaves collapsing to the arrow at its end.
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.ListRow).then(if (onOpen == null) toggle else Modifier)
        .padding(start = UiMetrics.GapLarge, end = if (onOpen == null) UiMetrics.GapLarge else UiMetrics.GapTiny),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        Icon(section.icon, null, Modifier.size(UiMetrics.Icon))
        Row(Modifier.weight(1f).then(if (onOpen != null) Modifier.heightIn(min = UiMetrics.Touch)
            .clickable(role = Role.Button, onClick = onOpen) else Modifier), verticalAlignment = Alignment.CenterVertically) {
            // Slack's section titles are 14 sp, a step under the rows.
            Text(section.label, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Icon(SlackIcons.ChevronRight, null, Modifier.size(UiMetrics.SmallIcon))
        }
        val arrow = @Composable { Icon(if (open) SlackIcons.ChevronUp else SlackIcons.ChevronDown, null, Modifier.size(UiMetrics.LargeIcon)) }
        if (onOpen == null) arrow()
        else Box(Modifier.size(UiMetrics.Touch).then(toggle).semantics { contentDescription = section.label },
            contentAlignment = Alignment.Center) { arrow() }
    }
}

/** Slack's Add channel row, closing the Channels section. */
@Composable
private fun AddChannelRow(onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(role = Role.Button, onClick = onClick)
        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapTiny), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        Icon(SlackIcons.Plus, null, Modifier.size(UiMetrics.Icon), tint = SlatrixTheme.colors.textBody)
        Text("Add channel", style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textBody)
    }
}

@Composable
private fun SectionDivider() {
    HorizontalDivider(Modifier.padding(vertical = UiMetrics.GapSmall), color = SlatrixTheme.colors.border)
}

@Composable
private fun DirectList(list: LazyListState, state: RoomListState, onRoom: (String) -> Unit, onActions: (RoomSummary) -> Unit) {
    val direct = remember(state.rooms) { state.rooms.filter { it.direct } }
    LazyColumn(Modifier.fillMaxSize(), list, contentPadding = PaddingValues(vertical = UiMetrics.GapSmall)) {
        if (state.loading) item { ConnectionIndicator(true, null) }
        items(direct, key = { it.id }) { LiveDirectRow(it, onRoom, onActions) }
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

@Composable
private fun LiveRoomRow(room: RoomSummary, onRoom: (String) -> Unit, onActions: (RoomSummary) -> Unit) {
    val colors = SlatrixTheme.colors
    val unread = room.unread != UnreadBadge.None
    val color = if (unread) colors.textPrimary else colors.textBody
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.ListRow).conversation(room, onRoom, onActions)
        .unreadState(room).padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapTiny),
        verticalAlignment = Alignment.CenterVertically) {
        if (room.direct) {
            LiveAvatar(room.initials, room.colorIndex, UiMetrics.CompactAvatar, room.avatarUrl)
            Spacer(Modifier.width(UiMetrics.GapMedium))
        } else {
            Icon(if (room.isPrivate) SlackIcons.Lock else SlackIcons.Hash, if (room.isPrivate) "Private channel" else null,
                Modifier.size(UiMetrics.Icon), tint = color)
            Spacer(Modifier.width(UiMetrics.GapLarge))
        }
        Text(room.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = color,
            fontWeight = if (unread) FontWeight.Bold else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis)
        UnreadCount(room.unread)
    }
}

/** A row of the DMs tab: the newest message under the name, and when it came, as Slack lists them. */
@Composable
private fun LiveDirectRow(room: RoomSummary, onRoom: (String) -> Unit, onActions: (RoomSummary) -> Unit) {
    val colors = SlatrixTheme.colors
    val unread = room.unread != UnreadBadge.None
    Row(Modifier.fillMaxWidth().conversation(room, onRoom, onActions).unreadState(room)
        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        LiveAvatar(room.initials, room.colorIndex, UiMetrics.ListAvatar, room.avatarUrl)
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                Text(room.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
                    fontWeight = if (unread) FontWeight.Bold else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis)
                room.latest?.let { Text(latestTime(it.timestamp), style = MaterialTheme.typography.bodySmall, color = colors.textBody) }
                UnreadCount(room.unread)
            }
            val latest = room.latest
            Text(when {
                latest?.body == null -> ""
                latest.own -> "You: ${latest.body}"
                else -> latest.body
            }, style = MaterialTheme.typography.bodyLarge, color = if (unread) colors.textPrimary else colors.textBody,
                minLines = 1, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** Slack's long-press sheet for a conversation: its name, then what can be done with it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConversationActions(room: RoomSummary, anyUnread: Boolean, onStar: (Boolean) -> Unit, onMarkUnread: (Boolean) -> Unit,
    onMarkAllRead: () -> Unit, onDismiss: () -> Unit) {
    val noun = if (room.direct) "conversation" else "channel"
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    // Applied once the sheet is gone, so its labels don't flip while it eases out.
    fun afterHiding(action: () -> Unit) { scope.launch { sheet.hide() }.invokeOnCompletion { action(); onDismiss() } }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet, shape = SlatrixTheme.topPanelShape,
        containerColor = SlatrixTheme.colors.overlay) {
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
    Surface(color = SlatrixTheme.colors.mention, contentColor = SlatrixTheme.colors.onAccent,
        shape = MaterialTheme.shapes.large) {
        Text(unread.label, Modifier.padding(horizontal = UiMetrics.GapSmall, vertical = UiMetrics.GapTiny),
            style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
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
    Box(Modifier.size(size).clip(if (size > UiMetrics.Avatar) MaterialTheme.shapes.large else MaterialTheme.shapes.small)
        .background(DesignTokens.avatarColors[colorIndex]), contentAlignment = Alignment.Center) {
        // Two letters shrink to fit, so every avatar in a list has the same width.
        Text(initials, Modifier.padding(horizontal = UiMetrics.GapTiny), style = AvatarStyle.label, color = SlatrixTheme.colors.onAccent,
            maxLines = 1, softWrap = false, autoSize = AvatarStyle.fit)
        Picture(url, size)
    }
}

/** The picture at [url] over whatever sits beneath it, once it has loaded, in the same box, so nothing moves. */
@Composable
private fun Picture(url: String?, size: Dp) {
    rememberAvatar(url, size)?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
}
