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
import ai.nuanu.slatrix.ui.designsystem.BottomSheet
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.glass
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
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
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
    Later("Later", SlackIcons.Bookmark, SlackIcons.BookmarkFilled),
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
    onInvitation: (String) -> Unit = {},
    /** Marks a conversation unread, or with false read. */
    onMarkUnread: suspend (String, Boolean) -> Boolean = { _, _ -> true },
    /** Marks these conversations read, and returns the ones that failed. */
    onMarkAllRead: suspend (List<String>) -> List<String> = { emptyList() },
    onNewMessage: (() -> Unit)? = null,
    /** Search, opened from Home's search bar over the whole screen; it calls back to close. */
    search: @Composable (onClose: () -> Unit) -> Unit = {}, userAvatarUrl: String? = null, activity: @Composable () -> Unit = {},
    later: @Composable () -> Unit = {}) {
    var tab by rememberSaveable { mutableStateOf(HomeTab.Home) }
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
    BackHandler(enabled = tab != HomeTab.Home && !searching) { tab = HomeTab.Home }
    if (searching) {
        Box(Modifier.fillMaxSize().background(colors.canvas)) { search { searching = false } }
        return
    }
    val glass = rememberGlass()
    // The lists scroll on under the tab capsule, and end clear of it.
    val clearance = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + UiMetrics.TabBar + UiMetrics.TabBarGap
    Box(Modifier.fillMaxSize().background(colors.canvas)) {
        Column(Modifier.fillMaxSize().glassSource(glass)) {
            HomeHeader(tab, userId, userAvatarUrl, state, selectedSpaceId, onSpace, onYou)
            Box(Modifier.weight(1f).fillMaxWidth()) {
                when (tab) {
                    HomeTab.Home -> Column {
                        HomeSearchBar(state.spaces.firstOrNull { it.id == selectedSpaceId }?.name) { searching = true }
                        HomeList(homeList, shown, selectedSpaceId, onRoom, onBrowseChannels,
                            (onBrowseChannels ?: onCreateChannel)?.let { { adding = true } }, onInvitation, clearance) { actions = it.id }
                    }
                    HomeTab.Dms -> DirectList(directList, shown, onRoom, clearance) { actions = it.id }
                    HomeTab.Activity -> Box(Modifier.padding(bottom = clearance)) { activity() }
                    HomeTab.Later -> Box(Modifier.padding(bottom = clearance)) { later() }
                }
                OfflineBanner()
            }
        }
        Row(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding()
            .padding(start = UiMetrics.GapLarge, end = UiMetrics.GapLarge, bottom = UiMetrics.TabBarGap - UiMetrics.GapSmall),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
            TabCapsule(glass, tab, Modifier.weight(1f)) { tab = it }
            // Slack's new message button, round beside the capsule.
            if (onNewMessage != null) Box(Modifier.size(UiMetrics.Fab)
                .shadow(UiMetrics.GapSmall, CircleShape, ambientColor = colors.accentFill, spotColor = colors.accentFill)
                .clip(CircleShape).background(colors.accentFill).clickable(role = Role.Button, onClick = onNewMessage)
                .semantics { contentDescription = "New message" }, contentAlignment = Alignment.Center) {
                Icon(SlackIcons.Compose, null, Modifier.size(UiMetrics.LargeIcon), tint = colors.onAccent)
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
private fun TabCapsule(glass: HazeState, tab: HomeTab, modifier: Modifier, onTab: (HomeTab) -> Unit) {
    val colors = SlatrixTheme.colors
    Row(modifier.heightIn(min = UiMetrics.TabBar).glass(glass, colors.glass, CircleShape, lifted = true)
        .padding(UiMetrics.TabInset).selectableGroup()) {
        HomeTab.entries.forEach { destination ->
            val selected = tab == destination
            val tint = if (selected) colors.accent else colors.textSecondary
            Column(Modifier.weight(1f).heightIn(min = UiMetrics.TabBar - UiMetrics.TabInset * 2).clip(CircleShape)
                .background(if (selected) colors.accentTint else colors.accentTint.copy(alpha = 0f))
                .selectable(selected, role = Role.Tab) { onTab(destination) },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Icon(if (selected) destination.selectedIcon else destination.icon, null, Modifier.size(UiMetrics.LargeIcon), tint = tint)
                Text(destination.label, style = MaterialTheme.typography.labelSmall,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium, color = tint, maxLines = 1)
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
    onBrowseChannels: (() -> Unit)?, onAddChannel: (() -> Unit)?, onInvitation: (String) -> Unit, bottom: Dp,
    onActions: (RoomSummary) -> Unit) {
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
    LazyColumn(Modifier.fillMaxSize(), list, contentPadding = PaddingValues(bottom = bottom)) {
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
                    SectionHeader(section, open, onBrowseChannels.takeIf { section == HomeSection.Channels }) {
                        collapsed = if (open) collapsed + section.name else collapsed - section.name
                    }
                }
                // A collapsed section keeps its unread conversations in view, as Slack's does.
                items(if (open) rooms else rooms.filter { it.unread != UnreadBadge.None }, key = { it.id }) {
                    ConversationRow(it, onRoom, onActions)
                }
                if (open && section == HomeSection.Channels && onAddChannel != null) item(key = "add-channel") { AddChannelRow(onAddChannel) }
            }
        }
    }
}

@Composable
private fun SectionHeader(section: HomeSection, open: Boolean, onOpen: (() -> Unit)?, onToggle: () -> Unit) {
    val colors = SlatrixTheme.colors
    val toggle = Modifier.clickable(role = Role.Button, onClickLabel = if (open) "Collapse" else "Expand", onClick = onToggle)
        .semantics(mergeDescendants = true) { stateDescription = if (open) "Expanded" else "Collapsed" }
    // A section that opens something, as Slack's Channels › does, leaves collapsing to the arrow at its end.
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.SectionHeader).then(if (onOpen == null) toggle else Modifier)
        .padding(start = UiMetrics.GapLarge, end = if (onOpen == null) UiMetrics.GapLarge else UiMetrics.GapTiny),
        verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.weight(1f).then(if (onOpen != null) Modifier.heightIn(min = UiMetrics.Touch)
            .clickable(role = Role.Button, onClick = onOpen) else Modifier), verticalAlignment = Alignment.CenterVertically) {
            Text(section.label, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.labelLarge,
                color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (onOpen != null) Icon(SlackIcons.ChevronRight, null, Modifier.size(UiMetrics.SmallIcon), tint = colors.textSecondary)
        }
        val arrow = @Composable {
            Icon(if (open) SlackIcons.ChevronUp else SlackIcons.ChevronDown, null, Modifier.size(UiMetrics.Icon), tint = colors.textSecondary)
        }
        if (onOpen == null) arrow()
        else Box(Modifier.size(UiMetrics.Touch).then(toggle).semantics { contentDescription = section.label },
            contentAlignment = Alignment.Center) { arrow() }
    }
}

/** Slack's Add channel row, closing the Channels section, its plus where a channel's tile sits. */
@Composable
private fun AddChannelRow(onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.ConversationRow).clickable(role = Role.Button, onClick = onClick)
        .padding(horizontal = UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        Box(Modifier.size(UiMetrics.RowAvatar).clip(MaterialTheme.shapes.large).background(colors.raised), contentAlignment = Alignment.Center) {
            Icon(SlackIcons.Plus, null, Modifier.size(UiMetrics.LargeIcon), tint = colors.textSecondary)
        }
        Text("Add channel", style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary)
    }
}

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
 * Design B's two-line row: a person's picture or a channel's tile, the name in bold while unread, and under it the
 * newest message, who sent it, and the mention count; when it came sits at the end of the name's line.
 */
@Composable
private fun ConversationRow(room: RoomSummary, onRoom: (String) -> Unit, onActions: (RoomSummary) -> Unit) {
    val colors = SlatrixTheme.colors
    val unread = room.unread != UnreadBadge.None
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.ConversationRow).conversation(room, onRoom, onActions).unreadState(room)
        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        if (room.direct) LiveAvatar(room.initials, room.colorIndex, UiMetrics.RowAvatar, room.avatarUrl)
        else ChannelTile(room.isPrivate, UiMetrics.RowAvatar)
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

/** The newest message under a row's name: in a channel after its sender's first name, and yours after You. */
@Composable
private fun preview(room: RoomSummary): AnnotatedString {
    val latest = room.latest ?: return AnnotatedString("")
    val body = latest.body ?: return AnnotatedString("")
    val sender = when {
        latest.own -> "You: "
        room.direct -> null
        else -> latest.sender?.substringBefore(' ')?.let { "$it: " }
    }
    val color = SlatrixTheme.colors.textPrimary
    return remember(sender, body, color) {
        buildAnnotatedString {
            if (sender != null) withStyle(SpanStyle(color = color)) { append(sender) }
            append(body)
        }
    }
}

/** A channel's rounded tile: its # or, for a private one, its lock, on the accent's tint. */
@Composable
internal fun ChannelTile(private: Boolean, size: Dp) {
    val colors = SlatrixTheme.colors
    Box(Modifier.size(size).clip(if (size >= UiMetrics.RowAvatar) MaterialTheme.shapes.large else MaterialTheme.shapes.medium)
        .background(colors.accentTint), contentAlignment = Alignment.Center) {
        Icon(if (private) SlackIcons.Lock else SlackIcons.Hash, if (private) "Private channel" else null, Modifier.size(UiMetrics.LargeIcon),
            tint = colors.accent)
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
