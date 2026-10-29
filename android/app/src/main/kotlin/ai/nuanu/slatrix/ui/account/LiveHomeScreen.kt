package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.core.WorkspaceMembership
import ai.nuanu.slatrix.ui.designsystem.AvatarStyle
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.KeyboardArrowUp
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
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
    Home("Home", Icons.Outlined.Home, Icons.Filled.Home),
    Dms("DMs", Icons.Outlined.Forum, Icons.Filled.Forum),
    Activity("Activity", Icons.Outlined.Notifications, Icons.Filled.Notifications),
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
    activity: @Composable () -> Unit = {}) {
    var tab by rememberSaveable { mutableStateOf(HomeTab.Home) }
    var actions by remember { mutableStateOf<RoomSummary?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
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
                HomeHeader(tab, userId, state, selectedSpaceId, onSpace, onYou)
                Surface(Modifier.weight(1f).fillMaxWidth(), shape = SlatrixTheme.topPanelShape, color = colors.canvas) {
                    Box(Modifier.fillMaxSize()) {
                        when (tab) {
                            HomeTab.Home -> HomeList(homeList, state, selectedSpaceId, onRoom) { actions = it }
                            HomeTab.Dms -> DirectList(directList, state, onRoom) { actions = it }
                            HomeTab.Activity -> activity()
                        }
                        val failure = notice
                        if (failure != null) {
                            Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge)) { Text(failure) }
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
    actions?.let { room ->
        ConversationActions(room, { starred ->
            scope.launch {
                if (!onStar(room.id, starred)) notice = if (starred) "Couldn’t star ${room.name}." else "Couldn’t unstar ${room.name}."
            }
        }) { actions = null }
    }
    notice?.let { LaunchedEffect(it) { delay(UiMetrics.NoticeMillis); notice = null } }
}

@Composable
private fun HomeHeader(tab: HomeTab, userId: String, state: RoomListState, selectedSpaceId: String?, onSpace: (String?) -> Unit, onYou: () -> Unit) {
    var switching by remember { mutableStateOf(false) }
    CompositionLocalProvider(LocalContentColor provides SlatrixTheme.colors.onAccent) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = UiMetrics.RootHeaderHeight)
            .padding(horizontal = UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) {
                when (tab) {
                    HomeTab.Home -> {
                        Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(role = Role.Button) { switching = true }
                            .semantics { contentDescription = "Switch workspace" }, verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                            HeaderTitle(state.spaces.firstOrNull { it.id == selectedSpaceId }?.name
                                ?: if (selectedSpaceId == null) "All conversations" else "Home", Modifier.weight(1f, fill = false))
                            Icon(Icons.Outlined.ExpandMore, null, Modifier.size(UiMetrics.Icon))
                        }
                        DropdownMenu(expanded = switching, onDismissRequest = { switching = false }) {
                            CompositionLocalProvider(LocalContentColor provides SlatrixTheme.colors.textPrimary) {
                                DropdownMenuItem(text = { Text("All conversations") }, onClick = { switching = false; onSpace(null) },
                                    trailingIcon = { if (selectedSpaceId == null) Icon(Icons.Outlined.Check, "Selected") })
                                state.spaces.sortedWith(compareBy({ !it.isTopLevel }, { it.name.lowercase(Locale.ROOT) })).forEach { space ->
                                    DropdownMenuItem(text = { Text(space.name) }, onClick = { switching = false; onSpace(space.id) },
                                        leadingIcon = { LiveAvatar(space.initials, space.colorIndex, UiMetrics.CompactAvatar) },
                                        trailingIcon = { if (selectedSpaceId == space.id) Icon(Icons.Outlined.Check, "Selected") })
                                }
                            }
                        }
                    }
                    HomeTab.Dms -> HeaderTitle("Direct messages")
                    HomeTab.Activity -> HeaderTitle("Activity")
                }
            }
            Box(Modifier.sizeIn(minWidth = UiMetrics.Touch, minHeight = UiMetrics.Touch)
                .clickable(role = Role.Button, onClick = onYou).semantics { contentDescription = "You" }, contentAlignment = Alignment.Center) {
                LiveAvatar(AvatarPlaceholder.initials(userId.removePrefix("@").substringBefore(':')), AvatarPlaceholder.colorIndex(userId), UiMetrics.HeaderAvatar)
            }
        }
    }
}

@Composable
private fun HeaderTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
        maxLines = 1, overflow = TextOverflow.Ellipsis)
}

private enum class HomeSection(val label: String, val icon: ImageVector) {
    Starred("Starred", Icons.Outlined.StarOutline),
    Channels("Channels", Icons.Outlined.Tag),
    Direct("Direct messages", Icons.Outlined.Forum),
}

@Composable
private fun HomeList(list: LazyListState, state: RoomListState, selectedSpaceId: String?, onRoom: (String) -> Unit,
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
    LazyColumn(Modifier.fillMaxSize(), list, contentPadding = PaddingValues(vertical = UiMetrics.GapSmall)) {
        if (waiting) {
            item { ConnectionIndicator(true, null) }
        } else {
            sections.forEachIndexed { index, (section, rooms) ->
                if (index > 0) item(key = "divider-${section.name}") { SectionDivider() }
                val open = section.name !in collapsed
                item(key = section.name) {
                    SectionHeader(section, open) { collapsed = if (open) collapsed + section.name else collapsed - section.name }
                }
                // A collapsed section keeps its unread conversations in view, as Slack's does.
                items(if (open) rooms else rooms.filter { it.unread != UnreadBadge.None }, key = { it.id }) {
                    LiveRoomRow(it, onRoom, onActions)
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(section: HomeSection, open: Boolean, onToggle: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.ListRow).clickable(role = Role.Button, onClick = onToggle)
        .semantics(mergeDescendants = true) { stateDescription = if (open) "Expanded" else "Collapsed" }
        .padding(horizontal = UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        Icon(section.icon, null, Modifier.size(UiMetrics.Icon))
        Text(section.label, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
        Icon(if (open) Icons.Outlined.KeyboardArrowUp else Icons.Outlined.KeyboardArrowDown, null, Modifier.size(UiMetrics.LargeIcon))
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
            LiveAvatar(room.initials, room.colorIndex, UiMetrics.CompactAvatar)
            Spacer(Modifier.width(UiMetrics.GapMedium))
        } else {
            Icon(if (room.isPrivate) Icons.Outlined.Lock else Icons.Outlined.Tag, if (room.isPrivate) "Private channel" else null,
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
        LiveAvatar(room.initials, room.colorIndex, UiMetrics.ListAvatar)
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
private fun ConversationActions(room: RoomSummary, onStar: (Boolean) -> Unit, onDismiss: () -> Unit) {
    val noun = if (room.direct) "conversation" else "channel"
    ModalBottomSheet(onDismissRequest = onDismiss, shape = SlatrixTheme.topPanelShape, containerColor = SlatrixTheme.colors.overlay) {
        Column(Modifier.fillMaxWidth().padding(bottom = UiMetrics.GapLarge)) {
            Text(room.name, Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
                style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable { onStar(!room.starred); onDismiss() }
                .padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(if (room.starred) Icons.Filled.Star else Icons.Outlined.StarOutline, null, Modifier.size(UiMetrics.Icon))
                Text(if (room.starred) "Unstar $noun" else "Star $noun", style = MaterialTheme.typography.bodyLarge)
            }
        }
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
internal fun LiveAvatar(initials: String, colorIndex: Int, size: Dp = UiMetrics.Avatar) {
    Box(Modifier.size(size).clip(if (size > UiMetrics.Avatar) MaterialTheme.shapes.large else MaterialTheme.shapes.small)
        .background(DesignTokens.avatarColors[colorIndex]), contentAlignment = Alignment.Center) {
        // Two letters shrink to fit, so every avatar in a list has the same width.
        Text(initials, Modifier.padding(horizontal = UiMetrics.GapTiny), style = AvatarStyle.label, color = SlatrixTheme.colors.onAccent,
            maxLines = 1, softWrap = false, autoSize = AvatarStyle.fit)
    }
}
