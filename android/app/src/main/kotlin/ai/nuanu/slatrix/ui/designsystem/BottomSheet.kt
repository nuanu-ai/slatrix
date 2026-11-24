package ai.nuanu.slatrix.ui.designsystem

import android.view.WindowManager
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch

/** Triggers the enclosing [BottomSheet]'s animated slide-down exit before calling `onDismissRequest`. */
val LocalSheetDismiss = compositionLocalOf<(() -> Unit)?> { null }

/**
 * Slack's bottom sheet: springs in from the bottom on [Motion.spatial] over a scrim that tracks its position 1:1,
 * preserves fling velocity when settling, and smoothly slides down with its scrim fading out before invoking
 * [onDismissRequest]. With [onTop] it draws no scrim and reports its resting top so the screen behind can recede and
 * bring a message forward; [onDismissing] fires the instant a dismiss starts so that recede can unwind in lockstep.
 */
@Composable
fun BottomSheet(onDismissRequest: () -> Unit, containerColor: Color, onTop: ((Float) -> Unit)? = null,
    onDismissing: (() -> Unit)? = null, content: @Composable ColumnScope.() -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val currentDismiss by rememberUpdatedState(onDismissRequest)
    val currentDismissing by rememberUpdatedState(onDismissing)
    val shown = remember { Animatable(0f) }
    var height by remember { mutableIntStateOf(0) }
    val dragged = remember { Animatable(0f) }
    var dismissing by remember { mutableStateOf(false) }
    fun dismiss(velocity: Float = 0f) {
        if (dismissing) return
        dismissing = true
        currentDismissing?.invoke()
        scope.launch {
            val target = height.toFloat()
            if (target > 0f && !coroutineContext.isMotionReduced(context)) {
                // Fold entrance progress and drag into one continuous exit path, carrying release velocity.
                val start = ((1f - shown.value) * target + dragged.value).coerceIn(0f, target)
                shown.snapTo(1f)
                dragged.snapTo(start)
                dragged.animateTo(target, Motion.gentle(Motion.PixelThreshold), initialVelocity = velocity.coerceAtLeast(0f))
            }
            currentDismiss()
        }
    }
    Dialog({ dismiss() }, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        // The scrim below fades in with the sheet, in place of the window's own dim and animation.
        val view = LocalView.current
        val window = (view.parent as? DialogWindowProvider)?.window
        SideEffect {
            window?.run {
                clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
                setWindowAnimations(0)
                WindowCompat.getInsetsController(this, view).isAppearanceLightNavigationBars = containerColor.luminance() > 0.5f
            }
        }
        LaunchedEffect(shown) {
            if (coroutineContext.isMotionReduced(context)) shown.snapTo(1f)
            else shown.animateTo(1f, Motion.spatial(Motion.UnitThreshold))
        }
        val flick = with(LocalDensity.current) { UiMetrics.SheetDismissVelocity.toPx() }
        fun drag(delta: Float) {
            if (dismissing) return
            val next = (dragged.value + delta).coerceAtLeast(0f)
            scope.launch(start = CoroutineStart.UNDISPATCHED) { dragged.snapTo(next) }
        }
        fun settle(velocity: Float) {
            if (dismissing) return
            if (dragged.value > height * UiMetrics.SheetDismissShare || (dragged.value > 0f && velocity > flick)) dismiss(velocity)
            else scope.launch {
                if (coroutineContext.isMotionReduced(context)) dragged.snapTo(0f)
                else dragged.animateTo(0f, Motion.spatial(Motion.PixelThreshold), initialVelocity = velocity)
            }
        }
        // Content that can't scroll further up hands the rest of a downward drag to the sheet, as Material's sheet does.
        val handOff = remember {
            object : NestedScrollConnection {
                override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset =
                    if (!dismissing && available.y < 0 && dragged.value > 0f) Offset(0f, available.y).also { drag(available.y) } else Offset.Zero
                override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset =
                    if (!dismissing && available.y > 0 && source == NestedScrollSource.UserInput) Offset(0f, available.y).also { drag(available.y) }
                    else Offset.Zero
                override suspend fun onPreFling(available: Velocity): Velocity =
                    if (!dismissing && dragged.value > 0f) available.also { settle(it.y) } else Velocity.Zero
            }
        }
        Box(Modifier.fillMaxSize()) {
            // A sibling of the sheet, so a tap in the sheet never reaches it.
            Box(Modifier.fillMaxSize().then(if (onTop != null) Modifier
                else Modifier.graphicsLayer {
                    val visible = if (height > 0) (shown.value - dragged.value / height).coerceIn(0f, 1f) else shown.value
                    alpha = visible
                }.background(SlatrixTheme.colors.scrim))
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = { dismiss() })
                .semantics { contentDescription = "Close" })
            // Never under the status bar; the space above the sheet is the scrim's, and takes no touches of its own.
            Box(Modifier.fillMaxSize().statusBarsPadding().padding(top = UiMetrics.GapSection)) {
                Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                    .onSizeChanged { height = it.height }
                    // Before the slide, so it is where the sheet rests.
                    .then(if (onTop != null) Modifier.onGloballyPositioned { if (!dismissing) onTop(it.positionInWindow().y) } else Modifier)
                    .graphicsLayer { translationY = (1 - shown.value) * size.height + dragged.value }
                    .pointerInput(dismissing) {
                        if (!dismissing) return@pointerInput
                        awaitPointerEventScope {
                            while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
                        }
                    }
                    .nestedScroll(handOff)
                    .draggable(rememberDraggableState(::drag), Orientation.Vertical, enabled = !dismissing, onDragStopped = { settle(it) })
                    .clip(SlatrixTheme.topPanelShape).background(containerColor)
                    // The keyboard pushes the sheet up, so a field in it stays above the keyboard.
                    .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom))) {
                    Box(Modifier.fillMaxWidth().padding(vertical = UiMetrics.GapMedium), contentAlignment = Alignment.Center) {
                        Box(Modifier.size(UiMetrics.SheetHandleWidth, UiMetrics.SheetHandleHeight)
                            .background(SlatrixTheme.colors.borderStrong, CircleShape))
                    }
                    CompositionLocalProvider(LocalSheetDismiss provides { dismiss() }) {
                        content()
                    }
                }
            }
        }
    }
}

/** One of a sheet's actions: its icon and what it does, in [color] when it can't be undone. */
@Composable
fun MenuItem(icon: ImageVector, label: String, color: Color = SlatrixTheme.colors.textPrimary, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(role = Role.Button, onClick = onClick)
        .padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(UiMetrics.SheetIcon), tint = if (color == colors.textPrimary) colors.textSecondary else color)
        Text(label, style = MaterialTheme.typography.bodyLarge, color = color)
    }
}

/** What stays behind a sheet that brings something forward: blurred and dimmed as far as [shown] says, from 0 to 1. */
@Composable
fun Modifier.recede(shown: () -> Float): Modifier {
    val scrim = SlatrixTheme.colors.scrim
    return graphicsLayer {
        val radius = UiMetrics.SheetBlur.toPx() * shown()
        renderEffect = if (radius > 0f) BlurEffect(radius, radius) else null
    }.drawWithContent {
        drawContent()
        drawRect(scrim, alpha = shown())
    }
}

/** Lifts what a sheet brings forward off the screen receded behind it, on the tab capsule's soft shadow. */
@Composable
fun Modifier.lift(shape: Shape): Modifier {
    val colors = SlatrixTheme.colors
    return shadow(UiMetrics.GlassLift, shape, ambientColor = colors.glassShadow, spotColor = colors.glassShadow)
}
