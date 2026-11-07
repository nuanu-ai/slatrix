package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ImageShader
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.vector.PathParser
import kotlin.math.roundToInt

/**
 * The chat wallpaper: a calm gray under faint doodles of the app's own icons. It stays put behind the messages, and its
 * tile is drawn once per theme, so scrolling only repeats it.
 */
@Composable
fun Modifier.wallpaper(): Modifier {
    val colors = SlatrixTheme.colors
    return this then remember(colors) { Modifier.drawWithCache {
        val side = UiMetrics.WallpaperTile.toPx().roundToInt().coerceAtLeast(1)
        val tile = ImageBitmap(side, side)
        val unit = side / TileUnits
        val stroke = Stroke(StrokeUnits, cap = StrokeCap.Round, join = StrokeJoin.Round)
        CanvasDrawScope().draw(this, layoutDirection, Canvas(tile), Size(side.toFloat(), side.toFloat())) {
            scale(unit, unit, Offset.Zero) {
                // Each doodle also one tile over on every side, so one crossing an edge carries on in the next tile.
                for (doodle in Doodles) for (dx in Wrap) for (dy in Wrap) translate(doodle.x + dx, doodle.y + dy) {
                    rotate(doodle.turn, Offset.Zero) { drawPath(Paths[doodle.icon], colors.wallpaperDoodle, style = stroke) }
                }
            }
        }
        val doodles = ShaderBrush(ImageShader(tile, TileMode.Repeated, TileMode.Repeated))
        onDrawBehind {
            drawRect(colors.wallpaper)
            drawRect(doodles)
        }
    } }
}

private class Doodle(val x: Float, val y: Float, val turn: Float, val icon: Int)

/** The tile's side in the board's units, one per dp, with the board's dense density of 11 doodles per 120 by 120. */
private const val TileUnits = 240f
private const val StrokeUnits = 1.5f
private val Wrap = listOf(-TileUnits, 0f, TileUnits)

private val Paths = listOf(
    "M0 3a3 3 0 0 1 3-3h16a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3H8l-5 4v-4H3a3 3 0 0 1-3-3z", // message
    "M2 7h16M2 13h16M8 2 6 18M14 2l-2 16", // channel
    "M13.5 10a3.5 3.5 0 1 1-7 0 3.5 3.5 0 0 1 7 0zM13.5 10v1.5a2.5 2.5 0 0 0 5 0V10a8.5 8.5 0 1 0-3.4 6.8", // mention
    "M6 10l7-7a3.5 3.5 0 0 1 5 5l-9 9a5 5 0 0 1-7-7l8-8", // attachment
    "M0 0h14v20l-7-5-7 5z", // later
    "M9 0a9 9 0 1 1 0 18A9 9 0 0 1 9 0zM5.5 11c.9 1.2 2 1.8 3.5 1.8s2.6-.6 3.5-1.8M6.2 7h.01M11.8 7h.01", // reaction
    "M0 8l5 5L15 3M9 12l1 1L20 3", // read
    "M10 18s-8-5-8-10a4.5 4.5 0 0 1 8-2.5A4.5 4.5 0 0 1 18 8c0 5-8 10-8 10z", // heart
    "M3 14V9a6 6 0 0 1 12 0v5l2 2H1zM7 19a2 2 0 0 0 4 0", // activity
    "M7 0v14M0 7h14", // plus
    "M4 0a4 4 0 1 1 0 8 4 4 0 0 1 0-8z", // dot
).map { PathParser().parsePathString(it).toPath() }

/**
 * The board's icons and turns, four of each, scattered at least 28 units apart with each kind's twins kept apart, so the
 * tile shows no rows; x and y are each icon's top left.
 */
private val Doodles = listOf(
    Doodle(68f, 26f, 0f, 10), Doodle(199f, 151f, 0f, 5), Doodle(187f, 31f, 10f, 4), Doodle(77f, 145f, -10f, 0),
    Doodle(135f, 197f, -12f, 7), Doodle(130f, 86f, -6f, 6), Doodle(11f, 85f, 0f, 5), Doodle(14f, 209f, 12f, 7),
    Doodle(20f, 143f, -12f, 7), Doodle(127f, 21f, 12f, 7), Doodle(191f, 206f, 0f, 2), Doodle(76f, 207f, 0f, 9),
    Doodle(195f, 86f, -10f, 1), Doodle(4f, 26f, 0f, 10), Doodle(133f, 143f, -25f, 3), Doodle(67f, 90f, 0f, 5),
    Doodle(164f, 115f, 0f, 5), Doodle(41f, 179f, 0f, 10), Doodle(94f, 58f, 10f, 4), Doodle(223f, 117f, 0f, 9),
    Doodle(159f, -2f, 12f, 8), Doodle(167f, 175f, -6f, 6), Doodle(-10f, 173f, 6f, 6), Doodle(36f, 2f, 10f, 1),
    Doodle(43f, 59f, 10f, 4), Doodle(219f, -6f, -12f, 8), Doodle(156f, 57f, -10f, 1), Doodle(106f, 169f, 0f, 2),
    Doodle(104f, 116f, -10f, 1), Doodle(109f, 227f, 0f, 2), Doodle(51f, 122f, 0f, 9), Doodle(217f, 54f, -10f, 0),
    Doodle(71f, 175f, 6f, 6), Doodle(49f, 216f, 0f, 2), Doodle(80f, -3f, 10f, 0), Doodle(36f, 32f, -10f, 0),
    Doodle(13f, 53f, -25f, 3), Doodle(24f, 111f, 25f, 3), Doodle(169f, 144f, 12f, 8), Doodle(127f, 56f, 0f, 9),
    Doodle(222f, 201f, 0f, 10), Doodle(96f, 89f, -12f, 8), Doodle(165f, 85f, 10f, 4), Doodle(215f, 23f, 25f, 3),
)
