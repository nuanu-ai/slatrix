package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.designsystem.AvatarStyle
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.PersonOutline
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow

@Composable
fun LiveHomeScreen(userId: String, state: RoomListState, onRoom: (String) -> Unit, onYou: () -> Unit, onRetry: () -> Unit) {
    var directOnly by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    val colors = SlatrixTheme.colors
    val visible = state.rooms.filter { (!directOnly || it.direct) && it.name.contains(query, ignoreCase = true) }
    Column(Modifier.fillMaxSize().background(colors.frame)) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = UiMetrics.RootHeaderHeight)
            .padding(horizontal = UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
            Text(if (directOnly) "Direct messages" else userId.substringAfter(':', "Home"), Modifier.weight(1f),
                style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            Box(Modifier.sizeIn(minWidth = UiMetrics.Touch, minHeight = UiMetrics.Touch)
                .clickable(role = Role.Button, onClick = onYou).semantics { contentDescription = "You" }, contentAlignment = Alignment.Center) {
                LiveAvatar(AvatarPlaceholder.initials(userId.substringBefore(':')), AvatarPlaceholder.colorIndex(userId), compact = true)
            }
        }
        Surface(Modifier.weight(1f).fillMaxWidth(), shape = SlatrixTheme.topPanelShape, color = colors.canvas) {
            Box(Modifier.fillMaxSize()) {
                LazyColumn(Modifier.fillMaxSize()) {
                    item {
                        OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(UiMetrics.GapLarge),
                            placeholder = { Text(if (directOnly) "Find a conversation" else "Find a channel or conversation") },
                            leadingIcon = { Icon(Icons.Outlined.Search, null) }, singleLine = true, shape = MaterialTheme.shapes.large)
                    }
                    if (!directOnly) {
                        item { RoomSection("Channels") }
                        items(visible.filterNot { it.direct }, key = { it.id }) { LiveRoomRow(it, onRoom) }
                        item { HorizontalDivider(Modifier.padding(top = UiMetrics.GapSmall), color = colors.border) }
                        item { RoomSection("Direct messages") }
                    }
                    items(visible.filter { it.direct }, key = { it.id }) { LiveRoomRow(it, onRoom) }
                    if (state.loading) item { ConnectionIndicator(true, null) }
                    else if (visible.isEmpty()) item {
                        Text(if (query.isNotEmpty()) "No results" else if (directOnly) "No direct messages" else "Your conversations will appear here.",
                            Modifier.padding(UiMetrics.GapLarge), style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary)
                    }
                    item { Spacer(Modifier.height(UiMetrics.GapSection)) }
                }
                state.error?.let { message ->
                    Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge),
                        action = { TextButton(onClick = onRetry) { Text("Retry") } }) { Text(message) }
                }
            }
        }
        NavigationBar(containerColor = colors.canvas) {
            NavigationBarItem(selected = !directOnly, onClick = { directOnly = false }, icon = { Icon(Icons.Outlined.Home, null) }, label = { Text("Home") })
            NavigationBarItem(selected = directOnly, onClick = { directOnly = true }, icon = { Icon(Icons.AutoMirrored.Outlined.Chat, null) }, label = { Text("DMs") })
            NavigationBarItem(selected = false, onClick = onYou, icon = { Icon(Icons.Outlined.PersonOutline, null) }, label = { Text("You") })
        }
    }
}

@Composable
private fun RoomSection(label: String) {
    Text(label, Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapMedium),
        style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
}

@Composable
private fun LiveRoomRow(room: RoomSummary, onRoom: (String) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(role = Role.Button) { onRoom(room.id) }
        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        if (room.direct) LiveAvatar(room.initials, room.colorIndex, compact = true)
        else Icon(Icons.Outlined.Tag, null, Modifier.size(UiMetrics.CompactAvatar), tint = SlatrixTheme.colors.textSecondary)
        Text(room.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
            fontWeight = if (room.unread == UnreadBadge.None) FontWeight.Normal else FontWeight.Bold,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
        (room.unread as? UnreadBadge.Count)?.let { badge ->
            Surface(color = SlatrixTheme.colors.mention, contentColor = SlatrixTheme.colors.mentionText, shape = MaterialTheme.shapes.large) {
                Text(badge.label, Modifier.padding(horizontal = UiMetrics.GapSmall, vertical = UiMetrics.GapTiny),
                    style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
internal fun LiveAvatar(initials: String, colorIndex: Int, compact: Boolean = false) {
    val size = if (compact) UiMetrics.CompactAvatar else UiMetrics.Avatar
    Box(Modifier.sizeIn(minWidth = size, minHeight = size).clip(MaterialTheme.shapes.small)
        .background(DesignTokens.avatarColors[colorIndex]).padding(UiMetrics.GapTiny), contentAlignment = Alignment.Center) {
        Text(initials, style = AvatarStyle.label, color = SlatrixTheme.colors.onAccent, maxLines = 1, softWrap = false)
    }
}
