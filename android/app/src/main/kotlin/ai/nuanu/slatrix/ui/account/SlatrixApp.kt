package ai.nuanu.slatrix.ui.account

import android.content.ActivityNotFoundException
import ai.nuanu.slatrix.BuildConfig
import ai.nuanu.slatrix.core.AccountState
import ai.nuanu.slatrix.core.AppearancePreferences
import ai.nuanu.slatrix.core.MatrixAccount
import ai.nuanu.slatrix.core.IdentityState
import ai.nuanu.slatrix.core.IdentityVerification
import ai.nuanu.slatrix.core.MatrixRooms
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.MatrixWorkspace
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.WorkspacePreferences
import ai.nuanu.slatrix.push.NotificationTarget
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.ui.platform.LocalContext
import androidx.core.net.toUri
import kotlinx.coroutines.launch

@Composable
fun SlatrixApp(account: MatrixAccount, identity: IdentityVerification?, rooms: MatrixRooms?, workspace: MatrixWorkspace?,
    notification: NotificationTarget? = null, onNotificationHandled: (NotificationTarget) -> Unit = {}) {
    val state by account.state.collectAsState()
    RequestNotificationPermission(signedIn = state is AccountState.Connected, configured = BuildConfig.PUSH_GATEWAY.isNotEmpty())
    val context = LocalContext.current
    val appearance = remember(context) { AppearancePreferences(context) }
    var darkOverride by rememberSaveable { mutableStateOf(appearance.darkMode) }
    val dark = darkOverride ?: isSystemInDarkTheme()
    var palette by rememberSaveable { mutableStateOf(SidebarPalette.entries.firstOrNull { it.name == appearance.paletteName } ?: SidebarPalette.Aubergine) }
    var server by rememberSaveable { mutableStateOf("") }
    var you by rememberSaveable { mutableStateOf(false) }
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
                val workspacePreferences = remember(userId, context) { WorkspacePreferences(context, userId) }
                var selectedSpaceId by rememberSaveable(userId) { mutableStateOf(workspacePreferences.selectedSpaceId) }
                val identityState = identity?.state?.collectAsState()?.value ?: IdentityState()
                val roomState = rooms?.state?.collectAsState()?.value ?: RoomListState()
                val selected = workspace?.selected?.collectAsState()?.value
                LaunchedEffect(notification, userId, roomState.rooms, workspace) {
                    val target = notification ?: return@LaunchedEffect
                    if (target.userId != userId) {
                        onNotificationHandled(target)
                    } else if (workspace != null) {
                        target.roomFor(userId, roomState.rooms)?.let { room ->
                            you = false
                            workspace.open(room)
                            onNotificationHandled(target)
                        }
                    }
                }
                Box(Modifier.fillMaxSize()) {
                    ConnectedAccountScreen(identityState,
                        { identity?.requestVerification() }, { identity?.acceptVerification() },
                        { identity?.confirmMatch() }, { identity?.rejectMismatch() }, { identity?.recover(it) },
                        { identity?.cancel() }, { identity?.retry() }) {
                        when {
                            you -> LiveProfileScreen((state as AccountState.Connected).userId, dark, darkOverride, palette,
                                { darkOverride = it; appearance.darkMode = it },
                                { palette = it; appearance.paletteName = it.name }, { you = false })
                            selected != null -> key(selected.room.id) {
                                val conversation = selected.conversation
                                val composer = selected.composer
                                val timeline = conversation?.state?.collectAsState()?.value ?: ConversationState(error = selected.error)
                                val draft = composer?.state?.collectAsState()?.value ?: ComposerState()
                                val scope = androidx.compose.runtime.rememberCoroutineScope()
                                LiveChannelScreen(selected.room, timeline, draft, { composer?.edit(it) }, { composer?.send() },
                                    { workspace?.back() }, { conversation?.loadOlder() },
                                    { event -> scope.launch { conversation?.markRead(event) } },
                                    { if (draft.error != null) composer?.retry() else workspace?.open(selected.room) })
                            }
                            else -> LiveHomeScreen((state as AccountState.Connected).userId, roomState,
                                { id -> roomState.rooms.firstOrNull { it.id == id }?.let { workspace?.open(it) } },
                                { you = true }, { rooms?.retry() }, selectedSpaceId,
                                { selectedSpaceId = it; workspacePreferences.selectedSpaceId = it })
                        }
                    }
                    (state as AccountState.Connected).warning?.let { warning ->
                        Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge)) { Text(warning) }
                    }
                }
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
