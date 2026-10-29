package ai.nuanu.slatrix.ui.account

import android.content.ActivityNotFoundException
import ai.nuanu.slatrix.core.AccountState
import ai.nuanu.slatrix.core.AppearancePreferences
import ai.nuanu.slatrix.core.MatrixAccount
import ai.nuanu.slatrix.core.IdentityState
import ai.nuanu.slatrix.core.IdentityVerification
import ai.nuanu.slatrix.core.MatrixRooms
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.compose.BackHandler
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.net.toUri

@Composable
fun SlatrixApp(account: MatrixAccount, identity: IdentityVerification?, rooms: MatrixRooms?) {
    val state by account.state.collectAsState()
    val context = LocalContext.current
    val appearance = remember(context) { AppearancePreferences(context) }
    val dark = appearance.darkMode ?: isSystemInDarkTheme()
    val palette = SidebarPalette.entries.firstOrNull { it.name == appearance.paletteName } ?: SidebarPalette.Aubergine
    var server by rememberSaveable { mutableStateOf("") }
    BackHandler(enabled = state is AccountState.Connecting || state is AccountState.ChooseMethod || state is AccountState.BrowserSignIn) { account.cancel() }
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
                val identityState = identity?.state?.collectAsState()?.value ?: IdentityState()
                val roomState = rooms?.state?.collectAsState()?.value ?: RoomListState()
                ConnectedAccountScreen(identityState, roomState,
                    { identity?.requestVerification() }, { identity?.acceptVerification() },
                    { identity?.confirmMatch() }, { identity?.rejectMismatch() }, { identity?.recover(it) },
                    { identity?.cancel() }, { identity?.retry() })
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
            connecting?.restoring == true || failure?.canRetryRestore == true ->
                RestoreSessionScreen(connecting != null, failure?.message, account::restore, account::cancel)
            options != null && (options.password || options.oauth || options.sso) ->
                SignInMethodsScreen(options, connecting != null, failure?.message, account::signIn, account::signInWithBrowser, account::cancel)
            else -> AccountProviderScreen(server, { server = it }, connecting != null, failure?.message,
                { account.selectHomeserver(server) }, account::cancel)
        }
    }
}
