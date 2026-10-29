package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.AccountState
import ai.nuanu.slatrix.core.AppearancePreferences
import ai.nuanu.slatrix.core.MatrixAccount
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext

@Composable
fun SlatrixApp(account: MatrixAccount) {
    val state by account.state.collectAsState()
    val context = LocalContext.current
    val appearance = remember(context) { AppearancePreferences(context) }
    val dark = appearance.darkMode ?: isSystemInDarkTheme()
    val palette = SidebarPalette.entries.firstOrNull { it.name == appearance.paletteName } ?: SidebarPalette.Aubergine
    BackHandler(enabled = state is AccountState.Connecting) { account.cancel() }
    SlatrixTheme(dark = dark, palette = palette) {
        when (val current = state) {
            is AccountState.Connected -> Surface(Modifier.fillMaxSize(), color = SlatrixTheme.colors.canvas) {
                Column(Modifier.safeDrawingPadding().padding(UiMetrics.GapSection)) {
                    Text("Signed in", style = MaterialTheme.typography.headlineMedium)
                    Text(current.userId, style = MaterialTheme.typography.bodyLarge)
                    current.warning?.let { Text(it, color = SlatrixTheme.colors.destructive) }
                }
            }
            else -> {
                val failure = state as? AccountState.Failed
                SignInScreen(
                    connecting = state is AccountState.Connecting,
                    error = failure?.message,
                    onSignIn = account::signIn,
                    onCancel = account::cancel,
                    onRetryRestore = if (failure?.canRetryRestore == true) account::restore else null,
                )
            }
        }
    }
}
