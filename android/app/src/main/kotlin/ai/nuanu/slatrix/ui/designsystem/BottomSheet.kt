package ai.nuanu.slatrix.ui.designsystem

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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.foundation.shape.CircleShape
import kotlinx.coroutines.launch

/**
 * Slack's bottom sheet: it eases in from the bottom over the pane time, over a scrim that fades in with it, and closes at
 * once on a tap outside, Back, or a swipe down past a quarter of its height. Material's sheet takes its motion from a
 * scheme this Material version keeps internal, so the sheet is the design system's own.
 */
@Composable
fun BottomSheet(onDismissRequest: () -> Unit, containerColor: Color, content: @Composable ColumnScope.() -> Unit) {
    Dialog(onDismissRequest, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        // The scrim below fades in with the sheet, in place of the window's own dim and animation.
        val window = (LocalView.current.parent as? DialogWindowProvider)?.window
        SideEffect {
            window?.setDimAmount(0f)
            window?.setWindowAnimations(0)
        }
        val shown = remember { Animatable(0f) }
        LaunchedEffect(shown) { shown.animateTo(1f, Motion.pane()) }
        val scope = rememberCoroutineScope()
        var height by remember { mutableIntStateOf(0) }
        val dragged = remember { Animatable(0f) }
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = shown.value }.background(SlatrixTheme.colors.scrim)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button,
                onClickLabel = "Close", onClick = onDismissRequest)
            .statusBarsPadding().padding(top = UiMetrics.GapSection)) {
            Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().onSizeChanged { height = it.height }
                .graphicsLayer { translationY = (1 - shown.value) * size.height + dragged.value }
                .draggable(rememberDraggableState { delta -> scope.launch { dragged.snapTo((dragged.value + delta).coerceAtLeast(0f)) } },
                    Orientation.Vertical, onDragStopped = {
                        if (dragged.value > height * Motion.DismissDistance) onDismissRequest() else dragged.animateTo(0f, Motion.pane())
                    })
                .clip(SlatrixTheme.topPanelShape).background(containerColor)
                // Taps inside the sheet stay in it rather than reaching the scrim.
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = {})
                .navigationBarsPadding()) {
                Box(Modifier.fillMaxWidth().padding(vertical = UiMetrics.GapMedium), contentAlignment = Alignment.Center) {
                    Box(Modifier.size(UiMetrics.SheetHandleWidth, UiMetrics.SheetHandleHeight)
                        .background(SlatrixTheme.colors.borderStrong, CircleShape))
                }
                content()
            }
        }
    }
}
