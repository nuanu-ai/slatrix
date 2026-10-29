package ai.nuanu.slatrix.ui.designsystem

import android.view.WindowManager
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import kotlinx.coroutines.launch

/**
 * Slack's bottom sheet: it eases in from the bottom over the pane time, over a scrim that fades in with it, and closes at
 * once on a tap outside, Back, or a swipe or flick down, including one that starts on its scrolled-up content. Material's
 * sheet takes its motion from a scheme this Material version keeps internal, so the sheet is the design system's own.
 */
@Composable
fun BottomSheet(onDismissRequest: () -> Unit, containerColor: Color, content: @Composable ColumnScope.() -> Unit) {
    Dialog(onDismissRequest, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
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
        val shown = remember { Animatable(0f) }
        LaunchedEffect(shown) { shown.animateTo(1f, Motion.pane()) }
        val scope = rememberCoroutineScope()
        var height by remember { mutableIntStateOf(0) }
        val dragged = remember { Animatable(0f) }
        val flick = with(LocalDensity.current) { UiMetrics.SheetDismissVelocity.toPx() }
        fun drag(delta: Float) { scope.launch { dragged.snapTo((dragged.value + delta).coerceAtLeast(0f)) } }
        fun settle(velocity: Float) {
            if (dragged.value > height * UiMetrics.SheetDismissShare || (dragged.value > 0f && velocity > flick)) onDismissRequest()
            else scope.launch { dragged.animateTo(0f, Motion.pane()) }
        }
        // Content that can't scroll further up hands the rest of a downward drag to the sheet, as Material's sheet does.
        val handOff = remember {
            object : NestedScrollConnection {
                override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset =
                    if (available.y < 0 && dragged.value > 0f) Offset(0f, available.y).also { drag(available.y) } else Offset.Zero
                override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset =
                    if (available.y > 0 && source == NestedScrollSource.UserInput) Offset(0f, available.y).also { drag(available.y) }
                    else Offset.Zero
                override suspend fun onPreFling(available: Velocity): Velocity =
                    if (dragged.value > 0f) available.also { settle(it.y) } else Velocity.Zero
            }
        }
        Box(Modifier.fillMaxSize()) {
            // A sibling of the sheet, so a tap in the sheet never reaches it.
            Box(Modifier.fillMaxSize().graphicsLayer { alpha = shown.value }.background(SlatrixTheme.colors.scrim)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismissRequest)
                .semantics { contentDescription = "Close" })
            // Never under the status bar; the space above the sheet is the scrim's, and takes no touches of its own.
            Box(Modifier.fillMaxSize().statusBarsPadding().padding(top = UiMetrics.GapSection)) {
                Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                    .onSizeChanged { height = it.height }
                    .graphicsLayer { translationY = (1 - shown.value) * size.height + dragged.value }
                    .nestedScroll(handOff)
                    .draggable(rememberDraggableState(::drag), Orientation.Vertical, onDragStopped = { settle(it) })
                    .clip(SlatrixTheme.topPanelShape).background(containerColor)
                    // The keyboard pushes the sheet up, so a field in it stays above the keyboard.
                    .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom))) {
                    Box(Modifier.fillMaxWidth().padding(vertical = UiMetrics.GapMedium), contentAlignment = Alignment.Center) {
                        Box(Modifier.size(UiMetrics.SheetHandleWidth, UiMetrics.SheetHandleHeight)
                            .background(SlatrixTheme.colors.borderStrong, CircleShape))
                    }
                    content()
                }
            }
        }
    }
}
