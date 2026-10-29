package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.dp

/**
 * Slack's thin outlined icons, drawn on a 24-unit grid. Material's outlined set is drawn heavier, which reads as
 * another app beside Slack's text. `Icon` tints them like any other vector.
 */
object SlackIcons {
    val Hash = outline("hash", "M9.6 4 7.6 20 M16.4 4 14.4 20 M4.5 9 H20 M4 15 H19.5")
    val Lock = outline("lock", "M7 10.5 H17 A2 2 0 0 1 19 12.5 V18.5 A2 2 0 0 1 17 20.5 H7 A2 2 0 0 1 5 18.5 V12.5 A2 2 0 0 1 7 10.5 Z " +
        "M8.5 10.5 V8 A3.5 3.5 0 0 1 15.5 8 V10.5")
    val Messages = outline("messages", "$SmallBubble M9.52 12.13 A5.75 5.75 0 1 1 18.9 12.95 L20.25 16 L16.7 14.55")
    val MessagesFilled = filled("messages-filled", "$SmallBubble $BigBubble")
    val Home = vector("home", stroke = "$House", fill = Door)
    val HomeFilled = filled("home-filled", "$House $Door", evenOdd = true)
    val Search = outline("search", "M10.75 4.5 A6.25 6.25 0 1 1 10.75 17 A6.25 6.25 0 1 1 10.75 4.5 Z M15.4 15.4 L20 20")
    val SearchSelected = outline("search-selected", "M10.75 4.5 A6.25 6.25 0 1 1 10.75 17 A6.25 6.25 0 1 1 10.75 4.5 Z M15.4 15.4 L20 20", width = 2.5f)
    val Bell = outline("bell", "$BellBody M10 20.5 A2 2 0 0 0 14 20.5")
    val BellFilled = vector("bell-filled", stroke = "M10 20.5 A2 2 0 0 0 14 20.5", fill = BellBody)
    val Star = outline("star", Star5)
    val StarFilled = filled("star-filled", Star5)
    val ChevronRight = outline("chevron-right", "M9.5 6.5 L15 12 L9.5 17.5", width = 2f)
    val ChevronUp = outline("chevron-up", "M6.5 14.75 L12 9.25 L17.5 14.75", width = 2f)
    val ChevronDown = outline("chevron-down", "M6.5 9.25 L12 14.75 L17.5 9.25", width = 2f)
    val Preferences = outline("preferences", "M4 7.5 H8.5 M12.5 7.5 H20 M4 12 H14 M18 12 H20 M4 16.5 H6.5 M10.5 16.5 H20 " +
        "M10.5 5.5 A2 2 0 1 1 10.5 9.5 A2 2 0 1 1 10.5 5.5 Z M16 10 A2 2 0 1 1 16 14 A2 2 0 1 1 16 10 Z " +
        "M8.5 14.5 A2 2 0 1 1 8.5 18.5 A2 2 0 1 1 8.5 14.5 Z")
    val SignOut = outline("sign-out", "M10 4.5 H6.5 A1.5 1.5 0 0 0 5 6 V18 A1.5 1.5 0 0 0 6.5 19.5 H10 M14.5 8 L18.5 12 L14.5 16 " +
        "M18.5 12 H9.5")
    val Close = outline("close", "M6.5 6.5 L17.5 17.5 M17.5 6.5 L6.5 17.5")
    val Check = outline("check", "M5 12.5 L10 17.5 L19 7", width = 2f)
    /** A bubble with a dot at its corner, as Slack's Mark unread. */
    val MarkUnread = outline("mark-unread", "M13.5 5 H7 A2 2 0 0 0 5 7 V17 A2 2 0 0 0 7 19 H17 A2 2 0 0 0 19 17 V10.5 " +
        "M15.5 6.5 A2 2 0 1 0 19.5 6.5 A2 2 0 1 0 15.5 6.5 Z")
    val MarkRead = outline("mark-read", "M7 5 H17 A2 2 0 0 1 19 7 V17 A2 2 0 0 1 17 19 H7 A2 2 0 0 1 5 17 V7 A2 2 0 0 1 7 5 Z " +
        "M9 12.25 L11.25 14.5 L15.5 9.75")
    val MarkAllRead = outline("mark-all-read", "M3.5 12.5 L7.5 16.5 L15 8 M11.5 15.5 L12.5 16.5 L20 8")
    /** A clock with a turning-back arrow, for recent searches. */
    val History = outline("history", "M4.75 12 A7.25 7.25 0 1 0 6.9 6.85 M4.75 4.5 V8.25 H8.5 M12 8.25 V12 L14.75 14")
    val Offline = outline("offline", "M2.5 8.75 A13.5 13.5 0 0 1 21.5 8.75 M5.5 12.25 A9 9 0 0 1 18.5 12.25 " +
        "M8.75 15.75 A4.5 4.5 0 0 1 15.25 15.75 M12 19.5 L12 19.5 M4 4 L20 20")
    val Plus = outline("plus", "M12 5 V19 M5 12 H19")
    /** Slack's forward: an arrow that turns off to the right. */
    val Forward = outline("forward", "M14 5.5 L19.5 10.75 L14 16 M19.5 10.75 H11.5 A6.5 6.5 0 0 0 5 17.25 V18.5")
    val Bookmark = outline("bookmark", BookmarkShape)
    val BookmarkFilled = filled("bookmark-filled", BookmarkShape)
    val Tray = outline("tray", "M4 13 H8.5 L9.5 15.5 H14.5 L15.5 13 H20 M4 13 V18.5 A1.5 1.5 0 0 0 5.5 20 H18.5 " +
        "A1.5 1.5 0 0 0 20 18.5 V13 L17.5 5.5 H6.5 Z")

    private const val BookmarkShape = "M7.5 4.5 H16.5 A1 1 0 0 1 17.5 5.5 V19.5 L12 15.75 L6.5 19.5 V5.5 A1 1 0 0 1 7.5 4.5 Z"
    private const val BellBody = "M6 16.75 V11 A6 6 0 0 1 18 11 V16.75 L19.5 18.25 H4.5 Z"
    private const val SmallBubble = "M4 20.5 V16.25 A4.25 4.25 0 1 1 8.25 20.5 Z"
    private const val BigBubble = "M9.52 12.13 A5.75 5.75 0 1 1 18.9 12.95 L20.25 16 L16.7 14.55 A5.75 5.75 0 0 1 9.52 12.13 Z"
    private const val House = "M4.5 10.25 L12 4 L19.5 10.25 V18.5 A2 2 0 0 1 17.5 20.5 H6.5 A2 2 0 0 1 4.5 18.5 Z"
    private const val Door = "M10.75 14.5 A1.25 1.25 0 1 0 13.25 14.5 A1.25 1.25 0 1 0 10.75 14.5 Z"
    private const val Star5 = "M12 4 L14.29 9.59 L20.32 10.05 L15.71 13.96 L17.14 19.83 L12 16.65 L6.86 19.83 L8.29 13.96 " +
        "L3.68 10.05 L9.71 9.59 Z"

    private fun outline(name: String, path: String, width: Float = 1.75f) = vector(name, stroke = path, width = width)

    private fun filled(name: String, path: String, evenOdd: Boolean = false) = vector(name, fill = path, evenOdd = evenOdd)

    private fun vector(name: String, stroke: String? = null, fill: String? = null, width: Float = 1.75f, evenOdd: Boolean = false) =
        // The paths sit on a 24-unit grid with a 4-unit margin; Slack's glyphs fill more of their box, so 2 units are cropped.
        ImageVector.Builder(name, 24.dp, 24.dp, 20f, 20f).apply {
            addGroup(translationX = -2f, translationY = -2f)
            stroke?.let {
                addPath(PathParser().parsePathString(it).toNodes(), stroke = SolidColor(Color.Black), strokeLineWidth = width,
                    strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round)
            }
            fill?.let {
                addPath(PathParser().parsePathString(it).toNodes(), fill = SolidColor(Color.Black),
                    pathFillType = if (evenOdd) PathFillType.EvenOdd else PathFillType.NonZero)
            }
            clearGroup()
        }.build()
}
