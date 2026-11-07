package ai.nuanu.slatrix

import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.compose.ui.test.onNodeWithText
import kotlin.math.abs

/** Which avatar color the tile behind [initials] shows, read from the pixels just below the letters. */
fun ComposeContentTestRule.avatarColorBehind(initials: String, view: View): Int {
    // Below the initials, where the tile's shading has reached the color itself.
    val letters = onNodeWithText(initials, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
    val picture = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
    val shown = Color(picture.getPixel(letters.center.x.toInt(), (letters.bottom + (letters.bottom - letters.top) / 4).toInt()))
    fun distance(color: Color) = abs(color.red - shown.red) + abs(color.green - shown.green) + abs(color.blue - shown.blue)
    return DesignTokens.avatarColors.indices.minBy { distance(DesignTokens.avatarColors[it]) }
}
