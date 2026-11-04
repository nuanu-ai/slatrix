package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ChannelDirectory
import ai.nuanu.slatrix.core.ChannelDirectoryState
import ai.nuanu.slatrix.core.Channels
import ai.nuanu.slatrix.core.DirectoryChannel
import ai.nuanu.slatrix.core.MatrixRooms
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.listed
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.BottomSheet
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.Motion
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import ai.nuanu.slatrix.ui.designsystem.rememberPredictiveBack
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Slack's Browse channels: a search field over the channels of the open workspace, or of the server when none is.
 * A channel you're in opens, one you may join joins, and one that needs an invitation says so.
 */
@Composable
fun BrowseChannelsScreen(title: String, state: ChannelDirectoryState, joined: Set<String>, joining: String?, error: String?,
    onSearch: (String) -> Unit, onMore: () -> Unit, onChannel: (DirectoryChannel) -> Unit, onBack: () -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    // After the first answer, a search in flight keeps what was said, so a note never swaps for a spinner as you type.
    val answered = remember { booleanArrayOf(false) }
    if (!state.loading) answered[0] = true
    Box(Modifier.fillMaxSize()) {
        PushedPage(title, onBack) {
            item { SearchField(query, { query = it; onSearch(it) }, { onSearch(query) }, Modifier, "Search channels") }
            items(state.channels, key = { it.id }) { channel ->
                DirectoryRow(channel, channel.id in joined, joining == channel.id, joining == null) { onChannel(channel) }
            }
            when {
                state.error != null -> item { Note(state.error) }
                state.loading && !answered[0] -> item { DirectorySkeleton() }
                // Asks for the next page as the end comes into view.
                state.more -> item { LaunchedEffect(state.channels.size) { onMore() } }
                state.channels.isEmpty() -> item {
                    if (query.isBlank()) Note("No channels yet") else NothingFound(query.trim())
                }
            }
        }
        error?.let { Notice(it) }
    }
}

@Composable
private fun DirectoryRow(channel: DirectoryChannel, joined: Boolean, joining: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    val members = membersLabel(channel.members)
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.ConversationRow)
        .then(if (joined || channel.canJoin) Modifier.clickable(enabled = enabled, role = Role.Button, onClick = onClick) else Modifier)
        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        // One that needs an invitation shows its lock.
        Lead { ChannelGlyph(private = !joined && !channel.canJoin, colors.textSecondary) }
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                // The name gives way only to the count, which keeps to the right edge.
                Text(channel.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Medium, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                // The progress takes the count's place, so the row never changes size.
                if (joining) WaitingSpinner()
                else Row(Modifier.semantics(mergeDescendants = true) { contentDescription = members },
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
                    Icon(SlackIcons.Person, null, Modifier.size(UiMetrics.SmallIcon), tint = colors.textSecondary)
                    Text("${channel.members}", Modifier.clearAndSetSemantics {}, style = MaterialTheme.typography.labelMedium,
                        color = colors.textSecondary, maxLines = 1)
                }
            }
            val about = listOfNotNull(channel.rule.ifEmpty { null }, channel.topic).joinToString(" · ").ifEmpty { null }
            if (joined || about != null) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                if (joined) Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(SlackIcons.Check, null, Modifier.size(UiMetrics.SmallIcon), tint = colors.accent)
                    Text("Joined", style = MaterialTheme.typography.labelMedium, color = colors.textSecondary, maxLines = 1)
                }
                about?.let {
                    Text(it, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, maxLines = 1,
                        overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

/** A search that found nothing, said in the middle of the page with what it looked for. */
@Composable
private fun LazyItemScope.NothingFound(query: String) {
    val colors = SlatrixTheme.colors
    Column(Modifier.fillParentMaxHeight(EmptyHeight).fillMaxWidth().padding(UiMetrics.GapLarge),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge, Alignment.CenterVertically)) {
        Icon(SlackIcons.Search, null, Modifier.size(UiMetrics.RowAvatar), tint = colors.textSecondary)
        Text("No channels match “$query”", style = MaterialTheme.typography.titleMedium, color = colors.textPrimary)
    }
}

/** Rows of grey where channels will be, shown only if they take a moment, at the height the rows will have. */
@Composable
private fun DirectorySkeleton() {
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { delay(UiMetrics.ProgressDelayMillis); visible = true }
    if (!visible) return
    val fill = SlatrixTheme.colors.raised
    Column(Modifier.clearAndSetSemantics {}) {
        SkeletonLines.forEach { (name, topic) ->
            Row(Modifier.fillMaxWidth().height(UiMetrics.ConversationRow).padding(horizontal = UiMetrics.GapLarge),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
                Box(Modifier.size(UiMetrics.RowAvatar).background(fill, MaterialTheme.shapes.large))
                Column(verticalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                    Box(Modifier.fillMaxWidth(name).height(UiMetrics.SkeletonLine).background(fill, CircleShape))
                    Box(Modifier.fillMaxWidth(topic).height(UiMetrics.SkeletonLine).background(fill, CircleShape))
                }
            }
        }
    }
}

/** Each placeholder row's name and topic, as shares of the row, so the grey reads as varied text. */
private val SkeletonLines = listOf(0.35f to 0.7f, 0.25f to 0.6f, 0.4f to 0.8f, 0.3f to 0.65f, 0.45f to 0.75f)
private const val EmptyHeight = 0.6f

/**
 * Slack's Create a channel: a name, and a topic if you like, in the open workspace when there is one. Channels are
 * private and encrypted, as on the Mac.
 */
@Composable
fun CreateChannelScreen(workspace: String?, creating: Boolean, error: String?, onCreate: (name: String, topic: String) -> Unit,
    onBack: () -> Unit) {
    val colors = SlatrixTheme.colors
    var name by rememberSaveable { mutableStateOf("") }
    var topic by rememberSaveable { mutableStateOf("") }
    val back = rememberPredictiveBack(onBack = onBack)
    Box(Modifier.fillMaxSize().graphicsLayer {
        alpha = 1 - back.value
        translationX = back.value * Motion.PushDistance * size.width
    }.background(colors.canvas)) {
        Column(Modifier.fillMaxSize().navigationBarsPadding().imePadding()) {
            Row(Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = UiMetrics.ComposerMinHeight),
                verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack, modifier = Modifier.size(UiMetrics.Touch)) {
                    Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back")
                }
                Text("Create a channel", Modifier.weight(1f).padding(start = UiMetrics.GapSmall),
                    style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Box(Modifier.padding(end = UiMetrics.GapSmall), contentAlignment = Alignment.Center) {
                    TextButton({ onCreate(name.trim(), topic.trim()) }, enabled = name.isNotBlank() && !creating) {
                        Text("Create", fontWeight = FontWeight.Bold)
                    }
                    if (creating) WaitingSpinner()
                }
            }
            HorizontalDivider(color = colors.border)
            Column(Modifier.fillMaxWidth().padding(UiMetrics.GapLarge), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
                OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), enabled = !creating, singleLine = true,
                    label = { Text("Name") }, prefix = { Text("#") }, shape = MaterialTheme.shapes.small)
                OutlinedTextField(topic, { topic = it }, Modifier.fillMaxWidth(), enabled = !creating,
                    label = { Text("Topic (optional)") }, shape = MaterialTheme.shapes.small)
                Text(listOfNotNull(workspace?.let { "In $it." }, "Only people you invite can join.").joinToString(" "),
                    style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary)
            }
        }
        error?.let { Notice(it) }
    }
}

/** Slack's Add channel sheet: browse the channels there are, or create one. */
@Composable
internal fun AddChannelSheet(onBrowse: (() -> Unit)?, onCreate: (() -> Unit)?, onDismiss: () -> Unit) {
    BottomSheet(onDismissRequest = onDismiss, containerColor = SlatrixTheme.colors.overlay) {
        Column(Modifier.fillMaxWidth().padding(bottom = UiMetrics.GapLarge)) {
            @Composable
            fun choice(icon: ImageVector, label: String, action: () -> Unit) {
                Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(role = Role.Button) {
                    onDismiss(); action()
                }.padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(icon, null, Modifier.size(UiMetrics.Icon))
                    Text(label, style = MaterialTheme.typography.bodyLarge)
                }
            }
            onBrowse?.let { choice(SlackIcons.Hash, "Browse channels", it) }
            onCreate?.let { choice(SlackIcons.Plus, "Create a channel", it) }
        }
    }
}

/** Browse channels, live: the open workspace's channels or the server's, joined and opened from here. */
@Composable
fun LiveBrowseChannels(rooms: MatrixRooms?, spaceId: String?, onOpen: (RoomSummary) -> Unit, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    val client = rooms?.client
    val directory = remember(client, spaceId) { client?.let { ChannelDirectory(scope, it, spaceId) } }
    DisposableEffect(directory) {
        directory?.search("")
        onDispose { directory?.close() }
    }
    val state = directory?.state?.collectAsState()?.value ?: ChannelDirectoryState()
    val known = rooms?.state?.collectAsState()?.value?.rooms.orEmpty()
    val joined = remember(known) { known.map { it.id }.toSet() }
    var joining by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    BrowseChannelsScreen("Browse channels", state, joined, joining, error, { directory?.search(it) },
        { directory?.loadMore() }, { channel ->
            known.firstOrNull { it.id == channel.id }?.let(onOpen) ?: run {
                if (client == null || rooms == null) return@run
                joining = channel.id
                error = null
                scope.launch {
                    if (!Channels.join(client, channel)) error = "Couldn’t join ${channel.name}."
                    // A slow sync leaves the row Joined, to open with another tap.
                    else rooms.state.listed(channel.id)?.let(onOpen)
                    joining = null
                }
            }
        }, onBack)
    error?.let { LaunchedEffect(it) { delay(UiMetrics.NoticeMillis); error = null } }
}

/** Create a channel, live, in the open workspace if there is one, and open it. */
@Composable
fun LiveCreateChannel(rooms: MatrixRooms?, spaceId: String?, workspace: String?, onOpen: (RoomSummary) -> Unit,
    onNotice: (String) -> Unit, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var creating by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    CreateChannelScreen(workspace, creating, error, { name, topic ->
        val client = rooms?.client ?: return@CreateChannelScreen
        creating = true
        error = null
        scope.launch {
            val created = Channels.create(client, name, topic, spaceId, rooms.state)
            creating = false
            val room = created.room
            when {
                !created.made -> error = created.error
                room != null -> { created.error?.let(onNotice); onOpen(room) }
                // Made, but not listed yet: the form goes, so another Create can't make a second one.
                else -> { onNotice(created.error ?: "Created. It’ll show up in a moment."); onBack() }
            }
        }
    }, onBack)
    error?.let { LaunchedEffect(it) { delay(UiMetrics.NoticeMillis); error = null } }
}

/** A spinner that shows only after a moment, so a quick answer never flashes one. */
@Composable
internal fun WaitingSpinner() {
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { delay(UiMetrics.ProgressDelayMillis); visible = true }
    if (visible) CircularProgressIndicator(Modifier.size(UiMetrics.Icon))
}

@Composable
private fun Note(text: String) {
    Text(text, Modifier.padding(UiMetrics.GapLarge), style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textSecondary)
}

@Composable
private fun androidx.compose.foundation.layout.BoxScope.Notice(text: String) {
    Snackbar(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(UiMetrics.GapLarge)
        .semantics { liveRegion = LiveRegionMode.Polite }) { Text(text) }
}
