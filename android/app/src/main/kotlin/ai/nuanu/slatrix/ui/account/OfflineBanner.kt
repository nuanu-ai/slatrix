package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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

/**
 * Says the app is offline once a drop has lasted a moment, as the Mac's connection notice does: the SDK restores most
 * drops at once. It floats over the screen, so nothing under it moves.
 */
@Composable
fun OfflineBanner(offline: Boolean) {
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(offline) {
        if (offline) delay(UiMetrics.ConnectionNoticeMillis)
        shown = offline
    }
    // Just under the header, so the screen's title and actions stay in reach.
    Box(Modifier.fillMaxWidth().statusBarsPadding().padding(top = UiMetrics.RootHeaderHeight + UiMetrics.GapSmall),
        contentAlignment = Alignment.TopCenter) {
        AnimatedVisibility(shown, enter = fadeIn(tween(UiMetrics.OverlayMillis)), exit = fadeOut(tween(UiMetrics.OverlayMillis))) {
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
