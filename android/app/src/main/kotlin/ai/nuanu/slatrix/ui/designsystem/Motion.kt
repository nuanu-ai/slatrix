package ai.nuanu.slatrix.ui.designsystem

import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.withFrameNanos
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlin.coroutines.cancellation.CancellationException

/** Panes and overlays ease in over 120–150 ms, as on the Mac; everything else, leaving included, is instant. */
object Motion {
    const val PaneMillis = 140

    /** How far a pushed page comes from, as a share of its width. */
    const val PushDistance = 0.25f

    fun <T> pane(): FiniteAnimationSpec<T> = tween(PaneMillis, easing = FastOutSlowInEasing)
}

/**
 * Android's predictive back for a page: how far the back swipe has gone, from 0 to 1, for the page to play its way in
 * backwards under the finger. A swipe taken back eases the page home; let go, it calls [onBack].
 */
@Composable
fun rememberPredictiveBack(enabled: Boolean = true, onBack: () -> Unit): State<Float> {
    val progress = remember { Animatable(0f) }
    val back by rememberUpdatedState(onBack)
    PredictiveBackHandler(enabled) { events ->
        try {
            events.collect { progress.snapTo(it.progress) }
        } catch (cancelled: CancellationException) {
            withContext(NonCancellable) { progress.animateTo(0f, Motion.pane()) }
            throw cancelled
        }
        back()
        // A page that stays, as one busy saving does, returns once the frame that would have removed it has passed.
        withFrameNanos {}
        progress.snapTo(0f)
    }
    return progress.asState()
}
