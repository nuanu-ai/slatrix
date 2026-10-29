package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.FileKind
import ai.nuanu.slatrix.core.ChannelMember
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.NotificationChoice
import ai.nuanu.slatrix.core.NotificationSetting
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SpaceSummary
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.PersonAddAlt
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Workspaces
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.isTraversalGroup
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** What a conversation's details do; a failure throws, and its message is shown as is. */
data class ChannelDetailsActions(
    val members: suspend () -> List<ChannelMember> = { emptyList() },
    val save: suspend (name: String?, topic: String?) -> Unit = { _, _ -> },
    val leave: suspend () -> Unit = {},
    val invite: suspend (userId: String) -> Unit = {},
    val notifications: suspend () -> NotificationSetting = { NotificationSetting(NotificationChoice.Default, NotificationChoice.All) },
    val setNotifications: suspend (NotificationChoice) -> Unit = {},
    /** The room's pinned messages, read while the Pinned messages page shows. */
    val pins: @Composable () -> PinnedMessages = { PinnedMessages() },
    val files: @Composable () -> SharedFiles = { SharedFiles() },
    /** Adds the channel to a workspace or takes it out. */
    val setInWorkspace: suspend (spaceId: String, adding: Boolean) -> Unit = { _, _ -> },
)

/** Every message in a conversation, threads included, to find what was shared, and asking for older ones. */
data class SharedFiles(val state: ConversationState = ConversationState(), val onLoadMore: () -> Unit = {})

/** A conversation's pinned messages as they load, and unpinning one. */
data class PinnedMessages(val state: ConversationState = ConversationState(), val onUnpin: (ConversationMessage) -> Unit = {})

private enum class DetailsPage { Details, Members, Edit, Notifications, AddPeople, Pins, Files, Workspaces }

/**
 * Slack Android's channel details, opened from the conversation's header: its name and description, notifications,
 * members, adding people and leaving. Each part pushes its own page, and Back returns to the details.
 */
@Composable
fun ChannelDetailsScreen(room: RoomSummary, me: String?, actions: ChannelDetailsActions, onLeft: () -> Unit,
    onOpenMessage: (eventId: String) -> Unit, spaces: List<SpaceSummary> = emptyList(), onPerson: (userId: String) -> Unit = {},
    onBack: () -> Unit) {
    var page by rememberSaveable { mutableStateOf(DetailsPage.Details) }
    // Where Add people goes back to: the page it was opened from.
    var opener by rememberSaveable { mutableStateOf(DetailsPage.Details) }
    var loads by remember { mutableIntStateOf(0) }
    var notifications by remember { mutableStateOf<Result<NotificationSetting>?>(null) }
    LaunchedEffect(room.id, loads) { notifications = attempt { actions.notifications() } }
    // Outlives the pages, so going back doesn't cancel a change on its way.
    val scope = rememberCoroutineScope()
    val open = { next: DetailsPage -> opener = page; page = next }
    val details = { page = DetailsPage.Details }
    when (page) {
        DetailsPage.Details -> DetailsPage(room, notifications?.getOrNull(), actions, scope, onLeft, onBack, open, spaces.isNotEmpty())
        DetailsPage.Members -> MembersPage(room, me, actions, { open(DetailsPage.AddPeople) }, onPerson, details)
        DetailsPage.Edit -> EditPage(room, actions, scope, details)
        DetailsPage.Notifications -> NotificationsPage(notifications, actions, scope, { notifications = Result.success(it) },
            { loads++ }, details)
        DetailsPage.AddPeople -> AddPeoplePage(actions, scope) { page = opener }
        DetailsPage.Pins -> PinsPage(room, me, actions.pins(), onOpenMessage, details)
        DetailsPage.Files -> FilesPage(actions.files(), onOpenMessage, details)
        DetailsPage.Workspaces -> WorkspacesPage(room, spaces, actions, scope, details)
    }
}

private fun noun(room: RoomSummary) = if (room.direct) "conversation" else "channel"

@Composable
private fun DetailsPage(room: RoomSummary, notifications: NotificationSetting?, actions: ChannelDetailsActions, scope: CoroutineScope,
    onLeft: () -> Unit, onBack: () -> Unit, onPage: (DetailsPage) -> Unit, hasWorkspaces: Boolean) {
    val colors = SlatrixTheme.colors
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
        // While leaving, Back waits for the answer, so a leave the server took always closes the conversation.
        PushedPage(if (room.direct) "Conversation details" else "Channel details", { if (!leaving) onBack() }, action = {
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
                DetailsRow(Icons.Outlined.PushPin, "Pinned messages", room.pinned.size.takeIf { it > 0 }?.toString()) {
                    onPage(DetailsPage.Pins)
                }
                DetailsRow(Icons.Outlined.Description, "Files") { onPage(DetailsPage.Files) }
                if (hasWorkspaces && !room.direct) DetailsRow(Icons.Outlined.Workspaces, "Workspaces",
                    room.spaceIds.size.takeIf { it > 0 }?.toString()) { onPage(DetailsPage.Workspaces) }
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
private fun NotificationsPage(loaded: Result<NotificationSetting>?, actions: ChannelDetailsActions, scope: CoroutineScope,
    onChange: (NotificationSetting) -> Unit, onRetry: () -> Unit, onBack: () -> Unit) {
    val setting = loaded?.getOrNull()
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
            loaded?.exceptionOrNull()?.let { failure ->
                ErrorLine(failure.message.orEmpty())
                TextButton(onClick = onRetry, Modifier.padding(horizontal = UiMetrics.GapSmall)) { Text("Try again") }
            }
        }
    }
}

@Composable
private fun MembersPage(room: RoomSummary, me: String?, actions: ChannelDetailsActions, onAddPeople: () -> Unit,
    onPerson: (String) -> Unit, onBack: () -> Unit) {
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
                    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.WorkspaceRow)
                        .clickable(role = Role.Button) { onPerson(member.id) }.padding(horizontal = UiMetrics.GapLarge),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
                        LiveAvatar(member.initials, member.colorIndex, UiMetrics.ListAvatar, member.avatarUrl)
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

/** Slack's pinned list, the latest pin first; a tap opens the message where it is. */
@Composable
private fun PinsPage(room: RoomSummary, me: String?, pins: PinnedMessages, onOpenMessage: (String) -> Unit, onBack: () -> Unit) {
    val colors = SlatrixTheme.colors
    val messages = remember(pins.state.rows, room.pinned) {
        pins.state.rows.filterIsInstance<ConversationMessage>().filter { it.eventId in room.pinned }
            .sortedByDescending { room.pinned.indexOf(it.eventId) }
    }
    PushedPage("Pinned messages", onBack) {
        items(messages, key = { it.id }) { message ->
            Row(Modifier.fillMaxWidth().clickable { message.eventId?.let(onOpenMessage) }
                .padding(start = UiMetrics.GapLarge, top = UiMetrics.GapMedium, bottom = UiMetrics.GapMedium),
                horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
                LiveAvatar(message.initials, message.colorIndex, url = message.avatarUrl)
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                        Text(message.senderName, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.Bold, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text("${dayLabel(message.timestamp)} at ${timeLabel(message.timestamp)}", style = MaterialTheme.typography.bodySmall,
                            color = colors.textSecondary, maxLines = 1)
                    }
                    MessageBody(message, colors.textBody, me)
                }
                // Holds its place without the power to unpin, so rows line up either way.
                Box(Modifier.size(UiMetrics.Touch), contentAlignment = Alignment.Center) {
                    if (room.canPin) IconButton(onClick = { pins.onUnpin(message) }) {
                        Icon(Icons.Outlined.PushPin, "Unpin", Modifier.size(UiMetrics.Icon), tint = colors.textSecondary)
                    }
                }
            }
        }
        when {
            messages.isNotEmpty() -> Unit
            pins.state.loading && room.pinned.isNotEmpty() -> item { DelayedProgress() }
            else -> item {
                ErrorLine(pins.state.error ?: if (room.pinned.isEmpty()) "No pinned messages" else "Couldn’t load pins", colors.textSecondary)
            }
        }
    }
}

/**
 * The files and links shared in the conversation, newest first, as the Mac's Files lists them: a file opens its message
 * where it is, and a link opens in the browser.
 */
@Composable
private fun FilesPage(files: SharedFiles, onOpenMessage: (String) -> Unit, onBack: () -> Unit) {
    val colors = SlatrixTheme.colors
    val uris = LocalUriHandler.current
    val shared = remember(files.state.rows) {
        files.state.rows.asReversed().filterIsInstance<ConversationMessage>().flatMap { message ->
            if (message.kind == MessageKind.Attachment) listOf(message to null)
            else message.runs.mapNotNull { run -> run.link?.takeIf { it.startsWith("https://") || it.startsWith("http://") } }
                .distinct().map { message to it }
        }
    }
    PushedPage("Files", onBack) {
        items(shared, key = { (message, link) -> message.id + (link ?: "") }) { (message, link) ->
            Row(Modifier.fillMaxWidth().clickable { if (link != null) uris.openUri(link) else message.eventId?.let(onOpenMessage) }
                .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapMedium),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
                // A file shows by its name and type, as its row in the conversation does, not by its caption.
                val file = message.attachment.takeIf { link == null }
                val kind = file?.let { FileKind.of(it.name, it.mimeType) }
                if (kind != null) FileTile(kind)
                else Box(Modifier.size(UiMetrics.Avatar).background(colors.raised, MaterialTheme.shapes.small), contentAlignment = Alignment.Center) {
                    Icon(if (link != null) Icons.Outlined.Link else Icons.Outlined.Description, null, Modifier.size(UiMetrics.Icon),
                        tint = colors.textSecondary)
                }
                Column(Modifier.weight(1f)) {
                    Text(link ?: file?.name ?: message.body, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Bold,
                        color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(listOfNotNull(file?.let { kind?.label(it.name) }, "Shared by ${message.senderName}", dayLabel(message.timestamp))
                        .joinToString(" · "), style = MaterialTheme.typography.bodyMedium,
                        color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        val state = files.state
        when {
            state.loading -> item { DelayedProgress() }
            state.error != null -> item {
                ErrorLine(state.error, colors.textSecondary)
                TextButton(onClick = files.onLoadMore, Modifier.padding(horizontal = UiMetrics.GapSmall)) { Text("Try again") }
            }
            else -> {
                if (shared.isEmpty() && !state.loadingHistory) item { ErrorLine("Nothing shared yet", colors.textSecondary) }
                // Older history is asked for, as on the Mac, rather than paged through on its own in a long conversation. The
                // button stays while a page loads, so the end of the list doesn't move.
                if (state.hasMore) item {
                    TextButton(onClick = files.onLoadMore, Modifier.padding(horizontal = UiMetrics.GapSmall),
                        enabled = !state.loadingHistory) { Text("Load more") }
                }
            }
        }
    }
}

/**
 * The workspaces you're in, as the Mac's Manage workspaces lists them: a channel is added to one or taken out where your
 * power level lets you manage its channels, and one it's in only through another can hold it directly too.
 */
@Composable
private fun WorkspacesPage(room: RoomSummary, spaces: List<SpaceSummary>, actions: ChannelDetailsActions, scope: CoroutineScope,
    onBack: () -> Unit) {
    val colors = SlatrixTheme.colors
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // A change shows at once and holds until the workspaces read again agree, which can take a sync, as a star does on Home.
    var changed by remember { mutableStateOf(emptyMap<String, Boolean>()) }
    LaunchedEffect(room.parentIds) { changed = changed.filter { (id, direct) -> (id in room.parentIds) != direct } }
    PushedPage("Workspaces", onBack) {
        items(spaces, key = { it.id }) { space ->
            val direct = changed[space.id] ?: (space.id in room.parentIds)
            // A group, so each row's button is read with its workspace.
            Row(Modifier.fillMaxWidth().semantics { isTraversalGroup = true }.heightIn(min = UiMetrics.WorkspaceRow)
                .padding(start = UiMetrics.GapLarge, end = UiMetrics.GapSmall),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
                LiveAvatar(space.initials, space.colorIndex, UiMetrics.ListAvatar)
                Column(Modifier.weight(1f)) {
                    Text(space.name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Bold, maxLines = 1,
                        overflow = TextOverflow.Ellipsis)
                    if (!direct && space.id in room.spaceIds) Text("Through another workspace", style = MaterialTheme.typography.bodyMedium,
                        color = colors.textSecondary)
                }
                TextButton(enabled = space.canManageRooms && !busy, onClick = {
                    // A second tap before the button disables finds it busy.
                    if (busy) return@TextButton
                    busy = true
                    error = null
                    scope.launch {
                        attempt { actions.setInWorkspace(space.id, !direct) }
                            .onSuccess { changed = changed + (space.id to !direct) }.onFailure { error = it.message }
                        busy = false
                    }
                }) { Text(if (direct) "Remove" else "Add") }
            }
        }
        error?.let { item { ErrorLine(it) } }
    }
}

@Composable
private fun EditPage(room: RoomSummary, actions: ChannelDetailsActions, scope: CoroutineScope, onBack: () -> Unit) {
    var name by rememberSaveable { mutableStateOf(room.name) }
    var topic by rememberSaveable { mutableStateOf(room.topic) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // Only what changed is sent, so a description alone never fixes a computed name, such as a direct message's.
    val newName = name.trim().takeIf { it != room.name }
    val newTopic = topic.takeIf { it != room.topic }
    PushedPage(if (room.direct) "Edit conversation" else "Edit channel", onBack, action = {
        TextButton(enabled = (newName != null || newTopic != null) && name.isNotBlank() && !saving, onClick = {
            saving = true
            error = null
            scope.launch {
                attempt { actions.save(newName, newTopic) }.onSuccess { onBack() }.onFailure { error = it.message }
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
private fun AddPeoplePage(actions: ChannelDetailsActions, scope: CoroutineScope, onBack: () -> Unit) {
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
