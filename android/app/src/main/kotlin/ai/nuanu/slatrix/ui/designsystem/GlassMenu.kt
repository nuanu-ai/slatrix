package ai.nuanu.slatrix.ui.designsystem

import android.view.WindowManager
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat

/**
 * A long-press menu on glass: the screen blurs and dims, the pressed item is drawn again where it sat, [reactions] float
 * in a capsule above it and [items] on a card below. When there isn't room they move up or down together, and an item
 * taller than what's left shows its end. Without a [top] they sit in the middle. [end] puts them on the right, as under
 * your own message.
 */
@Composable
fun GlassMenu(onDismissRequest: () -> Unit, title: String, end: Boolean, top: Float?, lifted: (@Composable () -> Unit)?,
    reactions: (@Composable RowScope.() -> Unit)?, items: @Composable ColumnScope.() -> Unit) {
    Dialog(onDismissRequest, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        val colors = SlatrixTheme.colors
        val view = LocalView.current
        val window = (view.parent as? DialogWindowProvider)?.window
        val blur = with(LocalDensity.current) { UiMetrics.MenuBlur.toPx() }
        val shown = remember { Animatable(0f) }
        // A phone saving power, or one without blur, gets solid cards on a deeper dim, so nothing reads through them.
        val blurs = remember { view.context.getSystemService(WindowManager::class.java).isCrossWindowBlurEnabled }
        val card = if (blurs) colors.glassMenu else colors.overlay
        SideEffect {
            window?.run {
                clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
                addFlags(WindowManager.LayoutParams.FLAG_BLUR_BEHIND)
                setWindowAnimations(0)
                val light = colors.canvas.luminance() > 0.5f
                WindowCompat.getInsetsController(this, view).run {
                    isAppearanceLightStatusBars = light
                    isAppearanceLightNavigationBars = light
                }
            }
        }
        // The blur deepens with the menu, so the screen behind never snaps out of focus.
        LaunchedEffect(window) {
            window ?: return@LaunchedEffect
            snapshotFlow { (shown.value * blur).toInt() }.collect { radius ->
                window.attributes = window.attributes.apply { blurBehindRadius = radius }
            }
        }
        LaunchedEffect(shown) { shown.animateTo(1f, Motion.pane()) }
        val shape = RoundedCornerShape(DesignTokens.radii.getValue("bubble").dp)
        // Grows from the side of the message it belongs to: the bar from its foot, the card from its head.
        fun Modifier.easesIn(from: Float) = graphicsLayer {
            alpha = shown.value
            scaleX = MenuStartScale + (1 - MenuStartScale) * shown.value
            scaleY = scaleX
            transformOrigin = TransformOrigin(if (end) 1f else 0f, from)
        }
        Box(Modifier.fillMaxSize().semantics { paneTitle = title }) {
            Box(Modifier.fillMaxSize().graphicsLayer { alpha = shown.value }.background(if (blurs) colors.dim else colors.scrim)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismissRequest)
                .semantics { contentDescription = "Close" })
            val density = LocalDensity.current
            val safe = WindowInsets.safeDrawing
            Layout(contents = listOf(
                { if (reactions != null) Row(Modifier.easesIn(1f).floating(CircleShape, card).height(UiMetrics.ReactionBar)
                    .padding(horizontal = UiMetrics.MenuInset), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.Hairline * 4), content = reactions) },
                // Drawn again only to be seen: the message itself stays where readers of the screen find it.
                { if (lifted != null) Box(Modifier.clipToBounds().clearAndSetSemantics {}) {
                    Box(Modifier.wrapContentHeight(Alignment.Bottom, unbounded = true)) { lifted() }
                } },
                { Column(Modifier.easesIn(0f).width(UiMetrics.MenuWidth).floating(shape, card).verticalScroll(rememberScrollState())
                    .padding(vertical = UiMetrics.MenuInset), content = items) },
            ), Modifier.fillMaxSize()) { (bar, row, card), constraints ->
                val gap = UiMetrics.GapSmall.roundToPx()
                val side = UiMetrics.GapMedium.roundToPx()
                val safeTop = safe.getTop(density) + gap
                val safeBottom = constraints.maxHeight - safe.getBottom(density) - gap
                val loose = Constraints(maxWidth = constraints.maxWidth - 2 * side)
                val barPlaced = bar.firstOrNull()?.measure(loose)
                val barSpace = barPlaced?.let { it.height + gap } ?: 0
                val cardPlaced = card.first().measure(loose.copy(maxHeight = (safeBottom - safeTop - barSpace).coerceAtLeast(0)))
                val rowRoom = (safeBottom - safeTop - barSpace - cardPlaced.height - gap).coerceAtLeast(0)
                val rowPlaced = row.firstOrNull()?.measure(Constraints(constraints.maxWidth, constraints.maxWidth, 0, rowRoom))
                val rowHeight = rowPlaced?.height ?: 0
                val stack = barSpace + rowHeight + gap + cardPlaced.height
                val rowTop = (top?.toInt() ?: ((safeTop + safeBottom - stack) / 2 + barSpace))
                    .coerceAtMost(safeBottom - cardPlaced.height - gap - rowHeight).coerceAtLeast(safeTop + barSpace)
                // Beside a message's picture, as its bubble starts, or at the right edge for your own.
                fun x(width: Int) = (if (end) constraints.maxWidth - side - width
                    else (UiMetrics.GapMedium + UiMetrics.FeedAvatar + UiMetrics.GapSmall).roundToPx())
                    .coerceIn(side, (constraints.maxWidth - side - width).coerceAtLeast(side))
                layout(constraints.maxWidth, constraints.maxHeight) {
                    barPlaced?.place(x(barPlaced.width), rowTop - barSpace)
                    rowPlaced?.place(0, rowTop)
                    cardPlaced.place(x(cardPlaced.width), rowTop + rowHeight + gap)
                }
            }
        }
    }
}

/** One of a [GlassMenu]'s actions: its icon and what it does, in [color] when it can't be undone. */
@Composable
fun MenuItem(icon: ImageVector, label: String, color: Color = SlatrixTheme.colors.textPrimary, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.MenuItem).clickable(role = Role.Button, onClick = onClick)
        .padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(UiMetrics.SheetIcon), tint = if (color == colors.textPrimary) colors.textSecondary else color)
        Text(label, style = MaterialTheme.typography.bodyLarge, color = color)
    }
}

/** A hairline between a [GlassMenu]'s groups. */
@Composable
fun MenuDivider() {
    Box(Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.MenuInset).fillMaxWidth().height(UiMetrics.Hairline * 2)
        .background(SlatrixTheme.colors.border))
}

/** A card of the menu in [fill], under a hairline edge and a soft shadow. */
@Composable
private fun Modifier.floating(shape: Shape, fill: Color): Modifier {
    val colors = SlatrixTheme.colors
    return shadow(UiMetrics.GlassLift, shape, ambientColor = colors.glassShadow, spotColor = colors.glassShadow)
        .clip(shape).background(fill).border(UiMetrics.Hairline, colors.glassEdge, shape)
}

private const val MenuStartScale = 0.9f
