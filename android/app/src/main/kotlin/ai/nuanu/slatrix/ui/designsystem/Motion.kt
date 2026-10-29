package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.tween

/** Panes and overlays ease in over 120–150 ms, as on the Mac; everything else, leaving included, is instant. */
object Motion {
    const val PaneMillis = 140

    /** How far a pushed page comes from, as a share of its width. */
    const val PushDistance = 0.25f

    /** How far down a sheet is dragged, as a share of its height, before letting go closes it. */
    const val DismissDistance = 0.25f

    fun <T> pane(): FiniteAnimationSpec<T> = tween(PaneMillis, easing = FastOutSlowInEasing)
}
