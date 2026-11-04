package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.drawscope.ContentDrawScope
import androidx.compose.ui.node.DrawModifierNode
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.node.invalidateDraw
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ImageShader
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.unit.dp
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import kotlin.math.roundToInt
import kotlin.math.tan

/** What a [glass] surface blurs: mark it with [glassSource], and keep the glass outside it. */
@Composable
fun rememberGlass(): HazeState = rememberHazeState()

fun Modifier.glassSource(state: HazeState): Modifier = hazeSource(state)

/**
 * Frosted glass: what scrolls beneath, blurred and washed with [tint], inside [shape] with a hairline edge. With
 * [lifted] it floats over the screen on a soft shadow, as the tab capsule does.
 */
@Composable
fun Modifier.glass(state: HazeState, tint: Color, shape: Shape, lifted: Boolean = false): Modifier {
    val colors = SlatrixTheme.colors
    return (if (lifted) shadow(UiMetrics.GlassLift, shape, ambientColor = colors.glassShadow, spotColor = colors.glassShadow) else this)
        .clip(shape)
        .hazeEffect(state, HazeStyle(backgroundColor = colors.canvas, tint = HazeTint(tint), blurRadius = UiMetrics.GlassBlur, noiseFactor = 0f))
        .border(UiMetrics.Hairline, colors.glassEdge, shape)
}

/** A chat header's glass, across the screen's top with a hairline under it. */
@Composable
fun Modifier.glassBar(state: HazeState): Modifier {
    val colors = SlatrixTheme.colors
    return hazeEffect(state, HazeStyle(backgroundColor = colors.canvas, tint = HazeTint(colors.glassHeader), blurRadius = UiMetrics.GlassBlur,
        noiseFactor = 0f)).drawWithContent {
        drawContent()
        drawLine(colors.glassEdge, Offset(0f, size.height), Offset(size.width, size.height), UiMetrics.Hairline.toPx())
    }
}

/** A bubble's fill in [shape], over a hairline of [edge] a little below it, which lifts it off the wallpaper. */
fun Modifier.bubble(shape: Shape, fill: Color, edge: Color): Modifier = this then BubbleElement(shape, fill, edge)

// An element compared by value, so recomposing a bubble's row, or the composer on every keystroke, leaves it alone.
private data class BubbleElement(val shape: Shape, val fill: Color, val edge: Color) : ModifierNodeElement<BubbleNode>() {
    override fun create() = BubbleNode(shape, fill, edge)
    override fun update(node: BubbleNode) {
        node.shape = shape
        node.fill = fill
        node.edge = edge
        node.outline = null
        node.invalidateDraw()
    }
}

private class BubbleNode(var shape: Shape, var fill: Color, var edge: Color) : Modifier.Node(), DrawModifierNode {
    var outline: Outline? = null
    private var outlineSize = Size.Unspecified

    override fun ContentDrawScope.draw() {
        if (outline == null || outlineSize != size) {
            outline = shape.createOutline(size, layoutDirection, this)
            outlineSize = size
        }
        val outline = outline!!
        translate(top = UiMetrics.Hairline.toPx() * 2) { drawOutline(outline, edge) }
        drawOutline(outline, fill)
        drawContent()
    }
}

/** The chat wallpaper: a wash from top to bottom, turned a little as the canvas's is, under a grid of faint dots. */
@Composable
fun Modifier.wallpaper(): Modifier {
    val colors = SlatrixTheme.colors
    // Remembered, so recomposing the conversation keeps the drawing cache instead of building the wash and dots again.
    return this then remember(colors) { Modifier.drawWithCache {
        val slant = size.height * tan(Math.toRadians(WashTurn)).toFloat() / 2
        val wash = Brush.linearGradient(0f to colors.wallpaperTop, WashMiddle to colors.wallpaperMiddle, 1f to colors.wallpaperBottom,
            start = Offset(size.width / 2 - slant, 0f), end = Offset(size.width / 2 + slant, size.height))
        val step = UiMetrics.WallpaperGrid.toPx().roundToInt().coerceAtLeast(1)
        val tile = ImageBitmap(step, step).also {
            Canvas(it).drawCircle(Offset(step / 2f, step / 2f), UiMetrics.WallpaperDot.toPx(), Paint().apply { color = colors.wallpaperDot })
        }
        val dots = ShaderBrush(ImageShader(tile, TileMode.Repeated, TileMode.Repeated))
        onDrawBehind {
            drawRect(wash)
            drawRect(dots)
        }
    } }
}

private const val WashTurn = 15.0
private const val WashMiddle = 0.55f

/**
 * A chat bubble: rounded all round except the corner toward its author, at the bottom, and the top one too when it
 * follows the same author's bubble, so a run of them reads as one.
 */
fun bubbleShape(own: Boolean, grouped: Boolean): Shape {
    val round = DesignTokens.radii.getValue("bubble").dp
    val tail = DesignTokens.radii.getValue("extraSmall").dp
    val top = if (grouped) tail else round
    return if (own) RoundedCornerShape(round, top, tail, round) else RoundedCornerShape(top, round, round, tail)
}
