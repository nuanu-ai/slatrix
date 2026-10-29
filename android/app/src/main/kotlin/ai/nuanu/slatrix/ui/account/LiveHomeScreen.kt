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
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Search
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
import java.util.Calendar
import java.util.Date
import java.util.Locale

private enum class HomeTab(val label: String, val icon: ImageVector) {
    Home("Home", Icons.Outlined.Home),
    Dms("DMs", Icons.AutoMirrored.Outlined.Chat),
    Activity("Activity", Icons.Outlined.Notifications),
}

/** Shows [cover], such as a conversation, in Home's place, and gives Home back its tab, search and scroll position after. */
@Composable
fun LiveWorkspace(cover: (@Composable () -> Unit)?, home: @Composable () -> Unit) {
    val saved = rememberSaveableStateHolder()
    if (cover != null) cover() else saved.SaveableStateProvider("home", home)
}

@Composable
fun LiveHomeScreen(userId: String, state: RoomListState, onRoom: (String) -> Unit, onYou: () -> Unit, onRetry: () -> Unit,
    selectedSpaceId: String? = null, onSpace: (String?) -> Unit = {}, activity: @Composable () -> Unit = {}) {
    var tab by rememberSaveable { mutableStateOf(HomeTab.Home) }
    var query by rememberSaveable { mutableStateOf("") }
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
                            icon = { Icon(destination.icon, null) }, label = { Text(destination.label) }, colors = navigationColors)
                    }
                }
            }
            Column(Modifier.weight(1f)) {
                HomeHeader(tab, userId, state, selectedSpaceId, onSpace, onYou)
                Surface(Modifier.weight(1f).fillMaxWidth(), shape = SlatrixTheme.topPanelShape, color = colors.canvas) {
                    Box(Modifier.fillMaxSize()) {
                        when (tab) {
                            HomeTab.Home -> HomeList(homeList, state, query, { query = it }, selectedSpaceId, onRoom)
                            HomeTab.Dms -> DirectList(directList, state, query, { query = it }, onRoom)
                            HomeTab.Activity -> activity()
                        }
                        state.error?.let { message ->
                            Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge),
                                action = { TextButton(onClick = onRetry) { Text("Retry") } }) { Text(message) }
                        }
                    }
                }
                if (!expanded) {
                    NavigationBar(containerColor = colors.canvas) {
                        val navigationColors = NavigationBarItemDefaults.colors(selectedTextColor = colors.textPrimary)
                        HomeTab.entries.forEach { destination ->
                            NavigationBarItem(selected = tab == destination, onClick = { tab = destination },
                                icon = { Icon(destination.icon, null) }, label = { Text(destination.label) }, colors = navigationColors)
                        }
                    }
                }
            }
        }
    }
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

@Composable
private fun SearchField(query: String, onQuery: (String) -> Unit, placeholder: String) {
    OutlinedTextField(query, onQuery, Modifier.fillMaxWidth().padding(UiMetrics.GapLarge),
        placeholder = { Text(placeholder) }, leadingIcon = { Icon(Icons.Outlined.Search, null) },
        singleLine = true, shape = MaterialTheme.shapes.large)
}

@Composable
private fun HomeList(list: LazyListState, state: RoomListState, query: String, onQuery: (String) -> Unit,
    selectedSpaceId: String?, onRoom: (String) -> Unit) {
    // A saved workspace's channels are known only with its spaces, so its list waits for them rather than filling in.
    val waiting = state.loading || (selectedSpaceId != null && !state.spacesKnown)
    val visible = remember(state.rooms, selectedSpaceId, query) {
        state.rooms.filter { WorkspaceMembership.includes(it.direct, it.spaceIds, selectedSpaceId) && it.name.contains(query, ignoreCase = true) }
    }
    val channels = remember(visible) { visible.filterNot { it.direct } }
    val direct = remember(visible) { visible.filter { it.direct } }
    LazyColumn(Modifier.fillMaxSize(), list) {
        item { SearchField(query, onQuery, "Find a channel or conversation") }
        if (waiting) {
            item { ConnectionIndicator(true, null) }
        } else {
            item { RoomSection("Channels") }
            items(channels, key = { it.id }) { LiveRoomRow(it, onRoom) }
            item { HorizontalDivider(Modifier.padding(top = UiMetrics.GapSmall), color = SlatrixTheme.colors.border) }
            item { RoomSection("Direct messages") }
            items(direct, key = { it.id }) { LiveRoomRow(it, onRoom) }
            if (visible.isEmpty()) item {
                EmptyList(if (query.isNotEmpty()) "No results" else "Your conversations will appear here.")
            }
        }
        item { Spacer(Modifier.height(UiMetrics.GapSection)) }
    }
}

@Composable
private fun DirectList(list: LazyListState, state: RoomListState, query: String, onQuery: (String) -> Unit, onRoom: (String) -> Unit) {
    val direct = remember(state.rooms, query) { state.rooms.filter { it.direct && it.name.contains(query, ignoreCase = true) } }
    LazyColumn(Modifier.fillMaxSize(), list) {
        item { SearchField(query, onQuery, "Find a conversation") }
        if (state.loading) item { ConnectionIndicator(true, null) }
        items(direct, key = { it.id }) { LiveDirectRow(it, onRoom) }
        if (!state.loading && direct.isEmpty()) item { EmptyList(if (query.isNotEmpty()) "No results" else "No direct messages") }
        item { Spacer(Modifier.height(UiMetrics.GapSection)) }
    }
}

@Composable
private fun EmptyList(text: String) {
    Text(text, Modifier.padding(UiMetrics.GapLarge), style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textSecondary)
}

@Composable
private fun RoomSection(label: String) {
    Text(label, Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapMedium),
        style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
}

@Composable
private fun LiveRoomRow(room: RoomSummary, onRoom: (String) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(role = Role.Button) { onRoom(room.id) }
        .unreadState(room).padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        if (room.direct) LiveAvatar(room.initials, room.colorIndex, UiMetrics.CompactAvatar)
        else Icon(Icons.Outlined.Tag, null, Modifier.size(UiMetrics.CompactAvatar), tint = SlatrixTheme.colors.textSecondary)
        Text(room.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
            fontWeight = if (room.unread == UnreadBadge.None) FontWeight.Normal else FontWeight.Bold,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
        UnreadCount(room.unread)
    }
}

/** A row of the DMs tab: the newest message under the name, and when it came, as Slack lists them. */
@Composable
private fun LiveDirectRow(room: RoomSummary, onRoom: (String) -> Unit) {
    val colors = SlatrixTheme.colors
    val unread = room.unread != UnreadBadge.None
    Row(Modifier.fillMaxWidth().clickable(role = Role.Button) { onRoom(room.id) }.unreadState(room)
        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapMedium),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        LiveAvatar(room.initials, room.colorIndex, UiMetrics.ListAvatar)
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                Text(room.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
                    fontWeight = if (unread) FontWeight.Bold else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis)
                room.latest?.let { Text(latestTime(it.timestamp), style = MaterialTheme.typography.bodySmall, color = colors.textSecondary) }
                UnreadCount(room.unread)
            }
            val latest = room.latest
            Text(when {
                latest?.body == null -> ""
                latest.own -> "You: ${latest.body}"
                else -> latest.body
            }, style = MaterialTheme.typography.bodyMedium, color = if (unread) colors.textPrimary else colors.textSecondary,
                minLines = 1, maxLines = 2, overflow = TextOverflow.Ellipsis)
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
