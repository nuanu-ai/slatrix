package ai.nuanu.slatrix.ui.account

import android.content.ActivityNotFoundException
import ai.nuanu.slatrix.BuildConfig
import ai.nuanu.slatrix.core.AccountState
import ai.nuanu.slatrix.core.AttachmentImport
import ai.nuanu.slatrix.core.ComposerTarget
import ai.nuanu.slatrix.core.AppearancePreferences
import ai.nuanu.slatrix.core.MatrixAccount
import ai.nuanu.slatrix.core.MatrixMedia
import java.io.File
import ai.nuanu.slatrix.core.MatrixChannel
import ai.nuanu.slatrix.core.MatrixForward
import org.matrix.rustcomponents.sdk.MessageType
import ai.nuanu.slatrix.core.MatrixConversation
import org.matrix.rustcomponents.sdk.Client
import ai.nuanu.slatrix.core.ConversationView
import ai.nuanu.slatrix.core.IdentityState
import ai.nuanu.slatrix.core.IdentityVerification
import ai.nuanu.slatrix.core.MatrixAvatars
import ai.nuanu.slatrix.core.MatrixRooms
import ai.nuanu.slatrix.core.MatrixSearch
import ai.nuanu.slatrix.core.MessageSearchState
import ai.nuanu.slatrix.core.RecentSearchStore
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.MatrixWorkspace
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.WorkspacePreferences
import ai.nuanu.slatrix.core.WorkspaceRail
import ai.nuanu.slatrix.push.NotificationTarget
import ai.nuanu.slatrix.push.PushNotifications
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.compose.BackHandler
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import kotlinx.coroutines.CancellationException
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.rememberCoroutineScope
import ai.nuanu.slatrix.core.OpenChannel
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.MatrixActivity
import ai.nuanu.slatrix.core.inWorkspace
import ai.nuanu.slatrix.core.MatrixThreadFeed
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.ThreadFeedState
import ai.nuanu.slatrix.core.WorkspaceMembership
import androidx.compose.runtime.setValue
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.ui.platform.LocalContext
import androidx.core.net.toUri
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun SlatrixApp(account: MatrixAccount, identity: IdentityVerification?, rooms: MatrixRooms?, workspace: MatrixWorkspace?,
    notification: NotificationTarget? = null, threads: MatrixWorkspace? = null, activity: MatrixActivity? = null,
    search: MatrixSearch? = null, onNotificationHandled: (NotificationTarget) -> Unit = {}) {
    val state by account.state.collectAsState()
    RequestNotificationPermission(signedIn = state is AccountState.Connected, configured = BuildConfig.PUSH_GATEWAY.isNotEmpty())
    val context = LocalContext.current
    val appearance = remember(context) { AppearancePreferences(context) }
    var darkOverride by rememberSaveable { mutableStateOf(appearance.darkMode) }
    val dark = darkOverride ?: isSystemInDarkTheme()
    var palette by rememberSaveable { mutableStateOf(SidebarPalette.entries.firstOrNull { it.name == appearance.paletteName } ?: SidebarPalette.Aubergine) }
    var server by rememberSaveable { mutableStateOf("") }
    var you by rememberSaveable { mutableStateOf(false) }
    var preferences by rememberSaveable { mutableStateOf(false) }
    // An invitation opened from Home, pushed over it.
    var invitation by rememberSaveable { mutableStateOf<String?>(null) }
    // Browse channels or Create a channel, pushed over Home; null while neither is open.
    var channels by rememberSaveable { mutableStateOf<ChannelPage?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    // Back during a restore leaves the app; cancelling would show sign-in with the session still saved.
    BackHandler(enabled = (state as? AccountState.Connecting)?.restoring == false || state is AccountState.ChooseMethod ||
        state is AccountState.BrowserSignIn || (state as? AccountState.Failed)?.let { it.options != null && !it.canRetryRestore } == true) {
        account.cancel()
    }
    var restoreFailed by remember { mutableStateOf(false) }
    LaunchedEffect(state) { if ((state as? AccountState.Failed)?.canRetryRestore == true) restoreFailed = true }
    SlatrixTheme(dark = dark, palette = palette) {
        val failure = state as? AccountState.Failed
        val connecting = state as? AccountState.Connecting
        val options = when (val current = state) {
            is AccountState.ChooseMethod -> current.options
            is AccountState.Connecting -> current.options
            is AccountState.Failed -> current.options
            else -> null
        }
        when {
            state is AccountState.Connected -> {
                val userId = (state as AccountState.Connected).userId
                val client = (state as AccountState.Connected).client
                val media = remember(client) { MatrixMedia(client, File(context.cacheDir, "media")) }
                val workspacePreferences = remember(userId, context) { WorkspacePreferences(context, userId) }
                var remembered by rememberSaveable(userId) { mutableStateOf(workspacePreferences.selectedSpaceId) }
                val identityState = identity?.state?.collectAsState()?.value ?: IdentityState()
                val selected = workspace?.selected?.collectAsState()?.value
                val avatars = remember(client) { SessionAvatars(MatrixAvatars(client)) }
                val userAvatarUrl by produceState<String?>(null, client) {
                    value = try { client.avatarUrl() } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null }
                }
                // Read inside derivedStateOf, so room list updates recompose the app only when the workspace changes.
                // Only a pick is saved: a fallback while spaces still load must not replace what the person chose.
                val roomList = rooms?.state?.collectAsState()
                val showing = rememberUpdatedState(selected?.room)
                val selectedSpaceId by remember(roomList, userId) {
                    derivedStateOf {
                        val list = roomList?.value
                        if (list?.spacesKnown == true) WorkspaceRail.choose(remembered, showing.value, list.spaces, list.rooms)
                        else remembered?.takeUnless { it == WorkspaceRail.AllToken }
                    }
                }
                val chooseSpace: (String?) -> Unit = { id ->
                    (id ?: WorkspaceRail.AllToken).let { remembered = it; workspacePreferences.selectedSpaceId = it }
                }
                val thread = threads?.selected?.collectAsState()?.value
                val covered = rememberSaveableStateHolder()
                // Opens a message highlighted in its conversation and a thread reply in its thread too: for notifications
                // and Activity, and next for search results and reply quotes.
                val jump: (RoomSummary, String, String?) -> Unit = remember(workspace, threads) {
                    { room, eventId, threadRoot ->
                        workspace?.jumpTo(room, eventId, threadRoot)
                        if (threadRoot != null) threads?.open(room, threadRoot, at = eventId) else threads?.back()
                    }
                }
                // The Threads filter's feed lives here, under the covers, so coming back from a thread finds it as it was.
                var threadRooms by remember(userId) { mutableStateOf<List<RoomSummary>?>(null) }
                var threadFeed by remember(userId) { mutableStateOf(ThreadFeedState()) }
                LaunchedEffect(rooms, threadRooms) {
                    val client = rooms?.client ?: return@LaunchedEffect
                    MatrixThreadFeed(this, client, userId, threadRooms ?: return@LaunchedEffect).state.collect { threadFeed = it }
                }
                LaunchedEffect(notification, userId, rooms, workspace) {
                    val target = notification ?: return@LaunchedEffect
                    if (target.userId != userId) {
                        onNotificationHandled(target)
                    } else if (workspace != null && rooms != null) {
                        val room = rooms.state.mapNotNull { target.roomFor(userId, it.rooms) }.first()
                        you = false
                        preferences = false
                        invitation = null
                        channels = null
                        jump(room, target.eventId, target.threadRoot)
                        onNotificationHandled(target)
                    }
                }
                CompositionLocalProvider(LocalAvatarLoader provides avatars) { Box(Modifier.fillMaxSize()) {
                    ConnectedAccountScreen(identityState,
                        { identity?.requestVerification() }, { identity?.acceptVerification() },
                        { identity?.confirmMatch() }, { identity?.rejectMismatch() }, { identity?.recover(it) },
                        { identity?.cancel() }, { identity?.retry() }) {
                        LiveWorkspace(when {
                            preferences -> { val client = (state as AccountState.Connected).client; { LivePreferencesScreen(dark, darkOverride, palette,
                                { darkOverride = it; appearance.darkMode = it },
                                { palette = it; appearance.paletteName = it.name }, { preferences = false }) {
                                    LiveNotificationSettings(userId) { client.getNotificationSettings() }
                                } } }
                            invitation != null -> { { invitation?.let { id ->
                                LiveInvitation(id, rooms, { room -> invitation = null; workspace?.open(room) },
                                    { space -> invitation = null; chooseSpace(space) }, { notice = it }) { invitation = null }
                            } } }
                            channels != null -> { {
                                val openChannel: (RoomSummary) -> Unit = { room -> channels = null; workspace?.open(room) }
                                if (channels == ChannelPage.Browse) LiveBrowseChannels(rooms, selectedSpaceId, openChannel) { channels = null }
                                else LiveCreateChannel(rooms, selectedSpaceId, roomList?.value?.spaces?.firstOrNull { it.id == selectedSpaceId }?.name,
                                    openChannel, { notice = it }) { channels = null }
                            } }
                            you -> { { LiveYouScreen(userId, { (state as? AccountState.Connected)?.client?.displayName() }, { preferences = true }, account::signOut,
                                onBack = { you = false }, avatarUrl = userAvatarUrl) } }
                            thread != null -> { { key(thread.room.id, thread.threadRoot) { LiveConversation(thread, threads, workspace, jump, rooms, media) } } }
                            // Kept while a thread covers it, so Back returns to the same place in the channel.
                            selected != null -> { { covered.SaveableStateProvider(selected.room.id) { key(selected.room.id) {
                                LiveConversation(selected, workspace, workspace, jump, rooms, media) { root, row -> threads?.open(selected.room, root, root = row) }
                            } } } }
                            else -> null
                        }) {
                            LiveHome(userId, userAvatarUrl, rooms, workspace, search, jump, { you = true }, selectedSpaceId, chooseSpace, { channels = it }, { invitation = it }) {
                                LiveActivity(activity, rooms, threads, selectedSpaceId, threadFeed, jump) { list ->
                                    if (list.map { it.id }.toSet() != threadRooms?.map { it.id }?.toSet()) threadRooms = list
                                }
                            }
                        }
                    }
                    notice?.let { LaunchedEffect(it) { delay(UiMetrics.NoticeMillis); notice = null } }
                    // One place for both, so a notice never sits on top of the account's warning.
                    (notice ?: (state as AccountState.Connected).warning)?.let { text ->
                        Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge)) { Text(text) }
                    }
                } }
            }
            state is AccountState.BrowserSignIn -> {
                val browser = state as AccountState.BrowserSignIn
                var error by remember(browser.attemptId) { mutableStateOf<String?>(null) }
                val open = {
                    try {
                        CustomTabsIntent.Builder().build().launchUrl(context, browser.url.toUri())
                        error = null
                    } catch (_: ActivityNotFoundException) { error = "Install a browser to continue." }
                }
                LaunchedEffect(browser.attemptId) { open() }
                BrowserSignInScreen(browser.options.homeserver, error, open, account::cancel)
            }
            // Like Slack's launch, a first restore shows only the background.
            connecting?.restoring == true && !restoreFailed -> Box(Modifier.fillMaxSize().background(SlatrixTheme.colors.canvas))
            connecting?.restoring == true || failure?.canRetryRestore == true ->
                RestoreSessionScreen(connecting != null, failure?.message, account::restore, account::signOut)
            options != null && (options.password || options.oauth || options.sso) ->
                SignInMethodsScreen(options, connecting != null, failure?.message, account::signIn, account::signInWithBrowser, account::cancel)
            else -> AccountProviderScreen(server, { server = it }, connecting != null, failure?.message,
                { account.selectHomeserver(server) }, account::cancel)
        }
    }
}

/** A channel, or with [OpenChannel.threadRoot] a thread, collected here so its updates recompose only this. */
@Composable
private fun LiveConversation(open: OpenChannel, owner: MatrixWorkspace?, main: MatrixWorkspace?,
    jump: (RoomSummary, String, String?) -> Unit, rooms: MatrixRooms?, media: MatrixMedia,
    onOpenThread: (root: String, row: ConversationMessage?) -> Unit = { _, _ -> }) {
    val context = LocalContext.current
    // The room as the list follows it, so a change of name, topic or permissions shows while it's open; read only
    // below, so other rooms' updates don't recompose the conversation.
    val roomList = rooms?.state?.collectAsState()
    val room by remember(open.room, roomList) {
        derivedStateOf { roomList?.value?.rooms?.firstOrNull { it.id == open.room.id } ?: open.room }
    }
    val conversation = open.conversation
    val composer = open.composer
    val timeline = conversation?.state?.collectAsState()?.value ?: ConversationState(error = open.error)
    val draft = composer?.state?.collectAsState()?.value ?: ComposerState()
    val scope = rememberCoroutineScope()
    var details by rememberSaveable(open.room.id) { mutableStateOf(false) }
    // The message and the copy read when Forward was tapped, so the copy is the message the page shows.
    var forwarding by remember { mutableStateOf<Pair<ConversationMessage, MessageType>?>(null) }
    var forwarded by remember { mutableStateOf<String?>(null) }
    forwarded?.let { LaunchedEffect(it) { delay(UiMetrics.NoticeMillis); forwarded = null } }
    Box(Modifier.fillMaxSize()) {
        LiveChannelScreen(room, timeline, draft, { composer?.edit(it); if (draft.target !is ComposerTarget.Edit) open.typing?.changed(it) }, { composer?.send(); open.typing?.stopped() },
            { owner?.back() }, { conversation?.loadOlder() },
            { event ->
                scope.launch {
                    if (conversation?.markRead(event) == true && open.threadRoot == null) PushNotifications(context).clear(open.room.id)
                }
            },
            { if (draft.error != null) composer?.retry() else if (conversation?.retry() != true) owner?.open(open.room, open.threadRoot, open.at.takeUnless { open.resume }) },
            { conversation?.retrySend(it) }, { conversation?.deleteUnsent(it) },
            { root -> onOpenThread(root, timeline.rows.firstOrNull { (it as? ConversationMessage)?.eventId == root } as? ConversationMessage) },
            open.threadRoot, rememberMessageActions(conversation, composer, main, room).let { remember(it) { it.copy(onForward = { m ->
                scope.launch { conversation?.forwardable(m)?.let { forwarding = m to it } ?: run { forwarded = "This message can’t be forwarded." } }
            }) } },
            ComposerActions(onCancelTarget = { composer?.cancelTarget() }, people = composer?.people?.collectAsState()?.value,
                onNeedPeople = { composer?.loadPeople() },
                onMention = { start, end, candidate -> composer?.mention(start, end, candidate) },
                onFormat = { start, end, kind, href -> composer?.format(start, end, kind, href) },
                onAttach = { uris -> conversation?.sendAttachments(uris.map { uri -> { AttachmentImport(context).prepare(uri) } }) }), { conversation?.loadNewer(it) },
            // A quote doesn't know its parent's thread, so it asks before jumping.
            { eventId -> scope.launch { jump(open.room, eventId, main?.threadRootOf(open.room.id, eventId)) } },
            { attachment, width, height, full -> media.picture(attachment, width, height, full) },
            { openAttachment(context, media, it) }, { details = true },
            typing = open.typing?.others?.collectAsState(emptyList())?.value.orEmpty())
        val actions = remember(rooms, open.room.id, conversation) {
            rooms?.client?.let { client ->
                val channel = MatrixChannel(client, open.room.id)
                ChannelDetailsActions(channel::members, channel::save, channel::leave, channel::invite, channel::notifications,
                    channel::setNotifications, setInWorkspace = { id, adding ->
                        channel.setInWorkspace(id, adding)
                        rooms.reloadSpaces()
                    }, pins = {
                    val pins = rememberConversation(client, open.room.id, ConversationView.Pins)
                    // Unpins through the conversation, which outlives the page, so going back doesn't cancel it.
                    PinnedMessages(pins?.state?.collectAsState()?.value ?: ConversationState(loading = false, error = "Couldn’t load pins")) {
                        conversation?.pin(it, false)
                    }
                }, files = {
                    val files = rememberConversation(client, open.room.id, ConversationView.Files)
                    val state = files?.state?.collectAsState()?.value ?: ConversationState(loading = false, error = "Couldn’t load files")
                    // Asks for the next page, which after a failed one is that page again.
                    SharedFiles(state) { files?.loadOlder() }
                })
            }
        }
        // Over the conversation, so Back finds it where it was.
        if (details && actions != null) {
            val spaces by remember(roomList) { derivedStateOf { roomList?.value?.spaces.orEmpty() } }
            ChannelDetailsScreen(room, timeline.ownUserId, actions, onLeft = { details = false; owner?.back() }, onOpenMessage = { id ->
                details = false
                // A pin doesn't know its thread, so it asks before jumping.
                scope.launch { jump(open.room, id, main?.threadRootOf(open.room.id, id)) }
            }, spaces) { details = false }
        }
        forwarding?.let { (message, content) ->
            ForwardScreen(message, room, roomList?.value?.rooms.orEmpty().filter { it.canPost }, { destination ->
                rooms?.client?.let { MatrixForward(it).forward(content, open.room.id, destination.id) } ?: "Couldn’t forward this message."
            }, { destination ->
                forwarding = null
                forwarded = if (destination.direct) "Forwarded to ${destination.name}." else "Forwarded to #${destination.name}."
            }) { forwarding = null }
        }
        forwarded?.let { Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge)) { Text(it) } }
    }
}

/** The room in [view], open while its caller shows: leaving cancels the scope, which closes it. */
@Composable
private fun rememberConversation(client: Client, roomId: String, view: ConversationView): MatrixConversation? {
    val scope = rememberCoroutineScope()
    return remember { runCatching { client.getRoom(roomId) }.getOrNull()?.let { MatrixConversation(scope, it, view = view) } }
}

/** Collects the room list here, so its updates recompose Home rather than the whole app. */
@Composable
private fun LiveHome(userId: String, userAvatarUrl: String?, rooms: MatrixRooms?, workspace: MatrixWorkspace?, search: MatrixSearch?,
    jump: (RoomSummary, String, String?) -> Unit, onYou: () -> Unit,
    selectedSpaceId: String?, onSpace: (String?) -> Unit, onChannels: (ChannelPage) -> Unit, onInvitation: (String) -> Unit,
    activity: @Composable () -> Unit) {
    val state = rooms?.state?.collectAsState()?.value ?: RoomListState()
    val scope = rememberCoroutineScope()
    val open: (String) -> Unit = remember(rooms, workspace) {
        { id -> rooms?.state?.value?.rooms?.firstOrNull { it.id == id }?.let { workspace?.open(it) } }
    }
    LiveHomeScreen(userId, state, open, onYou, { rooms?.retry() }, selectedSpaceId, onSpace,
        onStar = { id, starred -> rooms?.setStarred(id, starred) ?: false },
        onInvitation = onInvitation,
        onBrowseChannels = { onChannels(ChannelPage.Browse) }, onCreateChannel = { onChannels(ChannelPage.Create) },
        search = {
            val messages = search?.state?.collectAsState()?.value ?: MessageSearchState()
            val inScope = remember(state.rooms, selectedSpaceId) {
                state.rooms.filter { WorkspaceMembership.includes(it.direct, it.spaceIds, selectedSpaceId) }
            }
            val context = LocalContext.current
            val recentStore = remember(context, userId) { RecentSearchStore(context, userId) }
            var recents by remember(recentStore) { mutableStateOf(recentStore.recents) }
            SearchScreen(inScope, userId, messages, { query -> if (query == null) search?.clear() else search?.search(query) },
                { search?.loadMore() }, { hit ->
                    // A hit doesn't know its thread, so it is looked up first: a reply opens in its thread.
                    state.rooms.firstOrNull { it.id == hit.roomId }?.let { room ->
                        scope.launch { jump(room, hit.eventId, workspace?.threadRootOf(room.id, hit.eventId)) }
                    }
                }, recents, { recents = recentStore.add(it) }, open)
        }, userAvatarUrl = userAvatarUrl, activity = activity)
}

/** Collects Activity here, so a new item recomposes only its tab. An item opens at its message. */
@Composable
private fun LiveActivity(activity: MatrixActivity?, rooms: MatrixRooms?, threads: MatrixWorkspace?,
    selectedSpaceId: String?, threadFeed: ThreadFeedState, jump: (RoomSummary, String, String?) -> Unit,
    onThreadRooms: (List<RoomSummary>) -> Unit) {
    val all = activity?.items?.collectAsState()?.value.orEmpty()
    val known = rooms?.state?.collectAsState()?.value?.rooms.orEmpty()
    fun room(id: String) = known.firstOrNull { it.id == id }
    val items = remember(all, known, selectedSpaceId) { all.inWorkspace(known, selectedSpaceId) }
    ActivityScreen(items, { item -> activity?.markRead(item.id); room(item.roomId)?.let { jump(it, item.eventId, item.threadRoot) } },
        { id, root -> room(id)?.let { threads?.open(it, root) } }) {
        val inScope = remember(known, selectedSpaceId) { known.filter { WorkspaceMembership.includes(it.direct, it.spaceIds, selectedSpaceId) } }
        // Asks for the feed only while the Threads filter shows, and again only when the set of conversations changes.
        LaunchedEffect(inScope) { onThreadRooms(inScope) }
        ThreadsFeed(threadFeed, it)
    }
}

private enum class ChannelPage { Browse, Create }
