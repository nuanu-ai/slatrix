package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ConnectionState
import ai.nuanu.slatrix.ui.designsystem.Motion
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.ExitTransition
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.ButtonDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow

val LocalConnection = compositionLocalOf { ConnectionState.Connecting }
val LocalConnectionRetry = compositionLocalOf<(() -> Unit)?> { null }

/** Collects the connection here, so a change recomposes only the banners. */
@Composable
fun ProvideConnection(connection: StateFlow<ConnectionState>?, onRetry: (() -> Unit)? = null, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalConnection provides (connection?.collectAsState()?.value ?: ConnectionState.Connecting),
        LocalConnectionRetry provides onRetry, content = content)
}

/**
 * Says the app is offline once a drop has lasted a moment, as the Mac's connection notice does. It floats at the top
 * of the box it is in, under the screen's header, so nothing under it moves.
 */
@Composable
fun OfflineBanner() {
    val connection = LocalConnection.current
    val onRetry = LocalConnectionRetry.current
    val interrupted = connection != ConnectionState.Connected && connection != ConnectionState.Paused
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(interrupted) {
        if (interrupted) delay(UiMetrics.ConnectionNoticeMillis)
        shown = interrupted
    }
    Box(Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall), contentAlignment = Alignment.TopCenter) {
        AnimatedVisibility(shown, enter = fadeIn(Motion.pane()), exit = ExitTransition.None) {
            val colors = SlatrixTheme.colors
            Surface(Modifier.semantics { liveRegion = LiveRegionMode.Polite }, shape = MaterialTheme.shapes.extraLarge,
                color = colors.tooltip, contentColor = colors.onTooltip) {
                Row(Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
                    Icon(if (connection == ConnectionState.Offline) SlackIcons.Offline else SlackIcons.Reconnect,
                        null, Modifier.size(UiMetrics.SmallIcon))
                    Text(connection.label, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.labelLarge)
                    onRetry?.let { retry ->
                        TextButton(onClick = retry, colors = ButtonDefaults.textButtonColors(contentColor = colors.onTooltip)) { Text("Retry") }
                    }
                }
            }
        }
    }
}
