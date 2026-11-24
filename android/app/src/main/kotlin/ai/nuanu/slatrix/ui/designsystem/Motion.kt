package ai.nuanu.slatrix.ui.designsystem

import android.animation.ValueAnimator
import android.content.Context
import android.provider.Settings
import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.spring
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.MotionDurationScale
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/**
 * Modern messenger spring physics: critically damped spatial slides, crisp tactile snaps, and smooth gentle fades.
 * Animations preserve gesture velocity, remain interruptible, and respect Android's animator duration scale.
 */
object Motion {
    const val SpatialDamping = 0.88f
    const val SpatialStiffness = 380f
    const val SnappyDamping = 0.78f
    const val SnappyStiffness = 520f
    const val GentleDamping = 0.94f
    const val GentleStiffness = 320f

    /** How far a covered page parallaxes left as a pushed page slides over it. */
    const val PushParallax = 0.18f

    /** Maximum scrim alpha cast onto the page underneath a sliding page. */
    const val ScrimMaxAlpha = 0.22f

    /** Delay between consecutive quick-reaction emojis entering the message sheet. */
    const val ReactionStaggerMillis = 18L

    /** Visibility threshold for normalized 0..1 progress animations so full-width slides settle sub-pixel. */
    const val UnitThreshold = 0.001f

    /** Visibility threshold for pixel-space springs (sheets, swipes, media viewer) so exits finish right as they clear the edge. */
    const val PixelThreshold = 1f

    /** Critically damped responsive spring for screen push/pop, bottom sheets, composer banner height, focus lift. */
    fun <T> spatial(visibilityThreshold: T? = null): SpringSpec<T> =
        spring(dampingRatio = SpatialDamping, stiffness = SpatialStiffness, visibilityThreshold = visibilityThreshold)

    /** Crisp tactile spring for swipe-to-reply snap-back, bubble arrival, reaction chip pop, scroll-to-bottom FAB. */
    fun <T> snappy(visibilityThreshold: T? = null): SpringSpec<T> =
        spring(dampingRatio = SnappyDamping, stiffness = SnappyStiffness, visibilityThreshold = visibilityThreshold)

    /** Smooth exit and fade spring for highlight wash fade-out, scrims, and blur settle. */
    fun <T> gentle(visibilityThreshold: T? = null): SpringSpec<T> =
        spring(dampingRatio = GentleDamping, stiffness = GentleStiffness, visibilityThreshold = visibilityThreshold)
}

/** True when Android's animator duration scale is zero (Accessibility "Remove animations" or developer setting). */
internal fun isSystemMotionReduced(context: Context? = null): Boolean {
    if (!ValueAnimator.areAnimatorsEnabled()) return true
    return context != null &&
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
}

/** True when either Compose's [MotionDurationScale] or Android's animator duration scale is zero. */
internal fun CoroutineContext.isMotionReduced(context: Context? = null): Boolean =
    (this[MotionDurationScale]?.scaleFactor ?: 1f) == 0f || isSystemMotionReduced(context)

/**
 * Shared predictive-back state between a workspace container and its top page's [rememberPredictiveBack] handler.
 * Writes are token-owned so a cancelled spring from an earlier page can never leak into a newly pushed page; progress
 * is read only in graphicsLayer and draw scopes so dragging never recomposes either page.
 */
class BackProgressCoordinator {
    /** Current predictive-back swipe progress (0f = resting, 1f = fully swiped off). */
    val progress = mutableFloatStateOf(0f)

    /** True while an active gesture owns the coordinator, so a lingering tap-back exit yields immediately. */
    val active = mutableStateOf(false)

    /** Swipe progress captured right when a back gesture commits, so the exit slide continues from the release point. */
    var committedProgress: Float = 0f

    private var owner: Any? = null

    fun begin(token: Any) {
        owner = token
        active.value = true
    }

    fun update(token: Any, value: Float) {
        if (owner === token) progress.floatValue = value
    }

    fun commit(token: Any, value: Float) {
        if (owner === token) committedProgress = value
    }

    fun finish(token: Any) {
        if (owner === token) {
            progress.floatValue = 0f
            committedProgress = 0f
            active.value = false
            owner = null
        }
    }

    fun clear() {
        owner = null
        progress.floatValue = 0f
        committedProgress = 0f
        active.value = false
    }
}

/** Provided by `LiveWorkspace` to its top cover so predictive back drives both the top page and underlying parallax. */
val LocalBackProgress = compositionLocalOf<BackProgressCoordinator?> { null }

private val ZeroProgress = mutableFloatStateOf(0f)

/**
 * Android's predictive back for a page: tracks the finger 1:1 from 0 to 1, springs smoothly home on cancel, and hands
 * off to the enclosing workspace coordinator when hosted so the underlying page parallaxes in lockstep.
 */
@Composable
fun rememberPredictiveBack(enabled: Boolean = true, onBack: () -> Unit): State<Float> {
    val coordinator = LocalBackProgress.current
    val token = remember { Any() }
    val progress = remember { Animatable(0f) }
    val back by rememberUpdatedState(onBack)
    val context = LocalContext.current
    val hosted = coordinator != null
    DisposableEffect(coordinator) {
        onDispose { coordinator?.finish(token) }
    }
    PredictiveBackHandler(enabled) { events ->
        try {
            events.collect { event ->
                progress.snapTo(event.progress)
                coordinator?.begin(token)
                coordinator?.update(token, event.progress)
            }
        } catch (cancelled: CancellationException) {
            withContext(NonCancellable) {
                if (coroutineContext.isMotionReduced(context)) {
                    progress.snapTo(0f)
                    coordinator?.finish(token)
                } else {
                    progress.animateTo(0f, Motion.spatial(Motion.UnitThreshold)) {
                        coordinator?.update(token, value)
                    }
                    coordinator?.finish(token)
                }
            }
            throw cancelled
        }
        coordinator?.commit(token, progress.value)
        back()
        // A page that stays, as one busy saving does, springs smoothly back once the frame that would remove it passes.
        withFrameNanos {}
        coordinator?.commit(token, 0f)
        if (progress.value > 0f) {
            if (coroutineContext.isMotionReduced(context)) {
                progress.snapTo(0f)
                coordinator?.finish(token)
            } else {
                progress.animateTo(0f, Motion.spatial(Motion.UnitThreshold)) {
                    coordinator?.update(token, value)
                }
                coordinator?.finish(token)
            }
        } else {
            coordinator?.finish(token)
        }
    }
    // Inside LiveWorkspace the workspace translates the whole cover with its edge shadow, so return 0f to avoid doubling.
    return if (hosted) ZeroProgress else progress.asState()
}

/** Soft left-edge shadow cast beside a sliding page while [alpha] > 0; zero cost when at rest. */
@Composable
internal fun Modifier.pageEdgeShadow(alpha: () -> Float): Modifier {
    val shadow = SlatrixTheme.colors.glassShadow
    return drawWithContent {
        val a = alpha().coerceIn(0f, 1f)
        if (a > 0f) {
            val width = UiMetrics.GlassLift.toPx()
            drawRect(
                brush = Brush.horizontalGradient(
                    colors = listOf(Color.Transparent, shadow.copy(alpha = shadow.alpha * a)),
                    startX = -width,
                    endX = 0f,
                ),
                topLeft = Offset(-width, 0f),
                size = Size(width, size.height),
            )
        }
        drawContent()
    }
}

/** Soft dimming scrim cast over the page underneath a sliding page, fading 0..[Motion.ScrimMaxAlpha]. */
@Composable
internal fun Modifier.pageScrim(progress: () -> Float): Modifier {
    val scrim = SlatrixTheme.colors.scrim
    return drawWithContent {
        drawContent()
        val a = Motion.ScrimMaxAlpha * progress().coerceIn(0f, 1f)
        if (a > 0f) drawRect(scrim.copy(alpha = a))
    }
}
