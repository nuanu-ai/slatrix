package ai.nuanu.slatrix.ui.account

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

/** Whether the SDK has lost the server, for the banner each screen floats under its header. */
val LocalOffline = compositionLocalOf { false }

/** Collects the connection here, so a change recomposes only the banners. */
@Composable
fun ProvideOffline(offline: StateFlow<Boolean>?, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalOffline provides (offline?.collectAsState()?.value == true), content)
}

/**
 * Says the app is offline once a drop has lasted a moment, as the Mac's connection notice does. It floats at the top
 * of the box it is in, under the screen's header, so nothing under it moves.
 */
@Composable
fun OfflineBanner() {
    val offline = LocalOffline.current
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(offline) {
        if (offline) delay(UiMetrics.ConnectionNoticeMillis)
        shown = offline
    }
    Box(Modifier.fillMaxWidth().padding(top = UiMetrics.GapSmall), contentAlignment = Alignment.TopCenter) {
        AnimatedVisibility(shown, enter = fadeIn(Motion.pane()), exit = ExitTransition.None) {
            val colors = SlatrixTheme.colors
            Surface(Modifier.semantics { liveRegion = LiveRegionMode.Polite }, shape = MaterialTheme.shapes.extraLarge,
                color = colors.tooltip, contentColor = colors.onTooltip) {
                Row(Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
                    Icon(SlackIcons.Offline, null, Modifier.size(UiMetrics.SmallIcon))
                    Text("You’re offline. Check your connection.", style = MaterialTheme.typography.labelLarge)
                }
            }
        }
    }
}
