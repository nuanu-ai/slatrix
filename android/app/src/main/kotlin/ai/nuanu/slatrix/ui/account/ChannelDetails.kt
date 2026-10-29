package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ChannelMember
import ai.nuanu.slatrix.core.NotificationChoice
import ai.nuanu.slatrix.core.NotificationSetting
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Logout
import androidx.compose.material.icons.outlined.PeopleOutline
import androidx.compose.material.icons.outlined.PersonAddAlt
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** What a conversation's details do; a failure throws, and its message is shown as is. */
data class ChannelDetailsActions(
    val members: suspend () -> List<ChannelMember> = { emptyList() },
    val save: suspend (name: String, topic: String) -> Unit = { _, _ -> },
    val leave: suspend () -> Unit = {},
    val invite: suspend (userId: String) -> Unit = {},
    val notifications: suspend () -> NotificationSetting = { NotificationSetting(NotificationChoice.Default, NotificationChoice.All) },
    val setNotifications: suspend (NotificationChoice) -> Unit = {},
)

private enum class DetailsPage { Details, Members, Edit, Notifications, AddPeople }

/**
 * Slack Android's channel details, opened from the conversation's header: its name and description, notifications,
 * members, adding people and leaving. Each part pushes its own page, and Back returns to the details.
 */
@Composable
fun ChannelDetailsScreen(room: RoomSummary, me: String?, actions: ChannelDetailsActions, onLeft: () -> Unit, onBack: () -> Unit) {
    var page by rememberSaveable { mutableStateOf(DetailsPage.Details) }
    var notifications by remember { mutableStateOf<NotificationSetting?>(null) }
    LaunchedEffect(room.id) { notifications = attempt { actions.notifications() }.getOrNull() }
    val details = { page = DetailsPage.Details }
    when (page) {
        DetailsPage.Details -> DetailsPage(room, notifications, actions, onLeft, onBack) { page = it }
        DetailsPage.Members -> MembersPage(room, me, actions, { page = DetailsPage.AddPeople }, details)
        DetailsPage.Edit -> EditPage(room, actions, details)
        DetailsPage.Notifications -> NotificationsPage(notifications, actions, { notifications = it }, details)
        DetailsPage.AddPeople -> AddPeoplePage(actions, details)
    }
}

private fun noun(room: RoomSummary) = if (room.direct) "conversation" else "channel"

@Composable
private fun DetailsPage(room: RoomSummary, notifications: NotificationSetting?, actions: ChannelDetailsActions, onLeft: () -> Unit,
    onBack: () -> Unit, onPage: (DetailsPage) -> Unit) {
    val colors = SlatrixTheme.colors
    val scope = rememberCoroutineScope()
    var confirmLeave by rememberSaveable { mutableStateOf(false) }
    var leaving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    if (confirmLeave) AlertDialog(onDismissRequest = { confirmLeave = false },
        title = { Text("Leave ${room.name}?") }, text = { Text("You may need an invitation to rejoin.") },
        confirmButton = {
            TextButton(onClick = {
                confirmLeave = false
                leaving = true
                scope.launch {
                    attempt { actions.leave() }.onSuccess { onLeft() }.onFailure { error = it.message }
                    leaving = false
                }
            }) { Text("Leave", color = colors.destructive) }
        },
        dismissButton = { TextButton(onClick = { confirmLeave = false }) { Text("Cancel") } }, containerColor = colors.overlay)
    Box(Modifier.fillMaxSize()) {
        PushedPage(if (room.direct) "Conversation details" else "Channel details", onBack, action = {
            if (room.canEditName || room.canEditTopic) TextButton(onClick = { onPage(DetailsPage.Edit) }) { Text("Edit") }
        }) {
            item {
                Column(Modifier.fillMaxWidth().padding(UiMetrics.GapLarge), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                        if (!room.direct) Icon(if (room.isPrivate) SlackIcons.Lock else SlackIcons.Hash, null, Modifier.size(UiMetrics.LargeIcon))
                        Text(room.name, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
                            color = colors.textPrimary)
                    }
                    Text("Description", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold,
                        color = colors.textPrimary, modifier = Modifier.padding(top = UiMetrics.GapSmall))
                    Text(room.topic.ifBlank { "No description" }, style = MaterialTheme.typography.bodyLarge,
                        color = if (room.topic.isBlank()) colors.textSecondary else colors.textBody)
                }
                HorizontalDivider(color = colors.border)
                DetailsRow(SlackIcons.Bell, "Notifications", subtitle = notifications?.let { label(it.choice, it.default) }.orEmpty()) {
                    onPage(DetailsPage.Notifications)
                }
                HorizontalDivider(color = colors.border)
                DetailsRow(Icons.Outlined.PeopleOutline, "Members", room.memberCount.takeIf { it > 0 }?.toString()) {
                    onPage(DetailsPage.Members)
                }
                if (room.canInvite) DetailsRow(Icons.Outlined.PersonAddAlt, "Add people", chevron = false) { onPage(DetailsPage.AddPeople) }
                HorizontalDivider(color = colors.border)
                DetailsRow(Icons.AutoMirrored.Outlined.Logout, "Leave ${noun(room)}", color = colors.destructive, chevron = false,
                    enabled = !leaving) { confirmLeave = true }
            }
        }
        error?.let { message ->
            LaunchedEffect(message) { delay(UiMetrics.NoticeMillis); error = null }
            Snackbar(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(UiMetrics.GapLarge)) { Text(message) }
        }
    }
}

/**
 * A row of the details list: a short [value] at its end, or a [subtitle] under its label, whose line an empty one holds
 * while it loads, so arriving later moves nothing.
 */
@Composable
private fun DetailsRow(icon: ImageVector, label: String, value: String? = null, subtitle: String? = null,
    color: Color = SlatrixTheme.colors.textPrimary, chevron: Boolean = true, enabled: Boolean = true, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(enabled, role = Role.Button, onClick = onClick)
        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        Icon(icon, null, Modifier.size(UiMetrics.LargeIcon), tint = color)
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.bodyLarge, color = color)
            if (subtitle != null) Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary)
        }
        if (value != null) Text(value, style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, maxLines = 1)
        if (chevron) Icon(SlackIcons.ChevronRight, null, Modifier.size(UiMetrics.Icon), tint = colors.textSecondary)
    }
}

private fun title(choice: NotificationChoice) = when (choice) {
    NotificationChoice.All, NotificationChoice.Default -> "All new messages"
    NotificationChoice.Mentions -> "Mentions and keywords"
    NotificationChoice.Nothing -> "Nothing"
}

private fun label(choice: NotificationChoice, default: NotificationChoice) =
    if (choice == NotificationChoice.Default) "Default (${title(default)})" else title(choice)

@Composable
private fun NotificationsPage(setting: NotificationSetting?, actions: ChannelDetailsActions, onChange: (NotificationSetting) -> Unit,
    onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    PushedPage("Notifications", onBack) {
        item {
            Column(Modifier.selectableGroup()) {
                NotificationChoice.entries.forEach { choice ->
                    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch)
                        .selectable(setting?.choice == choice, enabled = setting != null && !saving, role = Role.RadioButton) {
                            val before = setting ?: return@selectable
                            // Shows at once, as Slack's does, and goes back if saving fails.
                            onChange(before.copy(choice = choice))
                            saving = true
                            error = null
                            scope.launch {
                                attempt { actions.setNotifications(choice) }.onFailure { onChange(before); error = it.message }
                                saving = false
                            }
                        }.padding(horizontal = UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                        Text(label(choice, setting?.default ?: NotificationChoice.All), Modifier.weight(1f),
                            style = MaterialTheme.typography.bodyLarge)
                        RadioButton(selected = setting?.choice == choice, onClick = null)
                    }
                }
            }
            error?.let { ErrorLine(it) }
        }
    }
}

@Composable
private fun MembersPage(room: RoomSummary, me: String?, actions: ChannelDetailsActions, onAddPeople: () -> Unit, onBack: () -> Unit) {
    val colors = SlatrixTheme.colors
    var query by rememberSaveable { mutableStateOf("") }
    var tries by remember { mutableIntStateOf(0) }
    var members by remember { mutableStateOf<Result<List<ChannelMember>>?>(null) }
    LaunchedEffect(tries) { members = attempt { actions.members() } }
    val shown = remember(members, query) {
        members?.getOrNull()?.filter { query.isBlank() || it.name.contains(query.trim(), true) || it.id.contains(query.trim(), true) }
    }
    PushedPage("Members", onBack) {
        item {
            Surface(Modifier.fillMaxWidth().padding(UiMetrics.GapLarge), shape = MaterialTheme.shapes.medium, color = colors.raised) {
                Row(Modifier.heightIn(min = UiMetrics.SearchField).padding(horizontal = UiMetrics.GapMedium),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.Search, null, Modifier.size(UiMetrics.Icon), tint = colors.textSecondary)
                    BasicTextField(query, { query = it }, Modifier.weight(1f).padding(start = UiMetrics.GapSmall)
                        .semantics { contentDescription = "Search members" },
                        textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.textBody),
                        cursorBrush = SolidColor(colors.accent), singleLine = true,
                        decorationBox = { inner ->
                            if (query.isEmpty()) Text("Search members", style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary)
                            inner()
                        })
                }
            }
            if (room.canInvite) DetailsRow(Icons.Outlined.PersonAddAlt, "Add people", color = colors.accent, chevron = false,
                onClick = onAddPeople)
        }
        when {
            shown != null -> {
                items(shown, key = { it.id }) { member ->
                    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.WorkspaceRow).padding(horizontal = UiMetrics.GapLarge),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
                        LiveAvatar(member.initials, member.colorIndex, UiMetrics.ListAvatar)
                        Text(member.name, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.bodyLarge,
                            fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (member.id == me) Text("(you)", style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary)
                    }
                }
                if (shown.isEmpty()) item { ErrorLine("No matches", colors.textSecondary) }
            }
            members?.isFailure == true -> item {
                Column(Modifier.fillMaxWidth().padding(UiMetrics.GapLarge), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(members?.exceptionOrNull()?.message.orEmpty(), style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary)
                    TextButton(onClick = { tries++ }) { Text("Retry") }
                }
            }
            else -> item { DelayedProgress() }
        }
    }
}

@Composable
private fun EditPage(room: RoomSummary, actions: ChannelDetailsActions, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var name by rememberSaveable { mutableStateOf(room.name) }
    var topic by rememberSaveable { mutableStateOf(room.topic) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val changed = name != room.name || topic != room.topic
    PushedPage(if (room.direct) "Edit conversation" else "Edit channel", onBack, action = {
        TextButton(enabled = changed && name.isNotBlank() && !saving, onClick = {
            saving = true
            error = null
            scope.launch {
                attempt { actions.save(name, topic) }.onSuccess { onBack() }.onFailure { error = it.message }
                saving = false
            }
        }) { Text("Save") }
    }) {
        item {
            Column(Modifier.fillMaxWidth().padding(UiMetrics.GapLarge), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
                OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), enabled = room.canEditName && !saving,
                    label = { Text("Name") }, singleLine = true, isError = name.isBlank())
                OutlinedTextField(topic, { topic = it }, Modifier.fillMaxWidth(), enabled = room.canEditTopic && !saving,
                    label = { Text("Description") })
                error?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = SlatrixTheme.colors.destructive) }
            }
        }
    }
}

@Composable
private fun AddPeoplePage(actions: ChannelDetailsActions, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var id by rememberSaveable { mutableStateOf("") }
    var inviting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val invite = {
        inviting = true
        error = null
        scope.launch {
            attempt { actions.invite(id) }.onSuccess { onBack() }.onFailure { error = it.message }
            inviting = false
        }
    }
    PushedPage("Add people", onBack, action = {
        TextButton(enabled = id.isNotBlank() && !inviting, onClick = { invite() }) { Text("Add") }
    }) {
        item {
            Column(Modifier.fillMaxWidth().padding(UiMetrics.GapLarge), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                OutlinedTextField(id, { id = it }, Modifier.fillMaxWidth(), enabled = !inviting, label = { Text("Matrix ID") },
                    placeholder = { Text("@name:example.org") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, imeAction = ImeAction.Done))
                error?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = SlatrixTheme.colors.destructive) }
            }
        }
    }
}

@Composable
private fun ErrorLine(message: String, color: Color = SlatrixTheme.colors.destructive) {
    Text(message, Modifier.fillMaxWidth().padding(UiMetrics.GapLarge), style = MaterialTheme.typography.bodyMedium, color = color)
}

/** A spinner that waits before showing, so a quick load never flashes one, in a row that keeps its height. */
@Composable
private fun DelayedProgress() {
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { delay(UiMetrics.ProgressDelayMillis); visible = true }
    Box(Modifier.fillMaxWidth().height(UiMetrics.Touch), contentAlignment = Alignment.Center) {
        if (visible) CircularProgressIndicator(Modifier.size(UiMetrics.Icon))
    }
}

/** [action]'s result, or its failure; cancellation still cancels. */
private suspend fun <T> attempt(action: suspend () -> T): Result<T> = try {
    Result.success(action())
} catch (cancelled: CancellationException) {
    throw cancelled
} catch (failure: Exception) {
    Result.failure(failure)
}
