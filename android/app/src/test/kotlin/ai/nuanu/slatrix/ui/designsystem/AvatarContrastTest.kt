package ai.nuanu.slatrix.ui.designsystem

import ai.nuanu.slatrix.core.AndroidTheme
import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35])
class AvatarContrastTest {
    @get:Rule val compose = createComposeRule()

    // capability: people.avatars
    @Test fun initialsMeetTheContrastRequirementAcrossEveryAvatarColorInEveryTheme() {
        val themes = mutableListOf<AppColors>()
        lateinit var view: View
        compose.setContent {
            view = LocalView.current
            for (theme in AndroidTheme.entries) for (dark in listOf(false, true)) for (highContrast in listOf(false, true)) {
                SlatrixTheme(dark = dark, theme = theme, increaseContrast = highContrast) { themes += SlatrixTheme.colors }
            }
            Column {
                for ((index, color) in DesignTokens.avatarColors.withIndex()) {
                    Box(Modifier.size(UiMetrics.Avatar).background(AvatarStyle.fill(color)).testTag("tile$index"))
                }
            }
        }
        compose.waitForIdle()
        val picture = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
        // On the tile as the avatar draws it, from its top to its foot.
        for (index in DesignTokens.avatarColors.indices) {
            val tile = compose.onNodeWithTag("tile$index").fetchSemanticsNode().boundsInRoot
            val column = (tile.top.toInt() until tile.bottom.toInt()).map { Color(picture.getPixel(tile.center.x.toInt(), it)) }
            assertTrue("A tile shades darker toward its foot", column.last().luminance() < column.first().luminance())
            for (colors in themes) for (background in column) {
                val ratio = contrast(colors.onAvatar, background)
                assertTrue("Avatar initials need 4.5:1 contrast on $background, got $ratio", ratio >= 4.5f)
            }
        }
    }

    private fun contrast(a: Color, b: Color): Float {
        val (light, dark) = listOf(a.luminance(), b.luminance()).sortedDescending()
        return (light + 0.05f) / (dark + 0.05f)
    }
}
