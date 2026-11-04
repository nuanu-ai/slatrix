package ai.nuanu.slatrix.ui.designsystem

import android.app.Application
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.test.junit4.createComposeRule
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class AvatarContrastTest {
    @get:Rule val compose = createComposeRule()

    // capability: people.avatars
    @Test fun initialsMeetTheContrastRequirementAcrossEveryAvatarColorInEveryTheme() {
        val themes = mutableListOf<AppColors>()
        compose.setContent {
            for (dark in listOf(false, true)) for (wallpaper in listOf(false, true)) {
                SlatrixTheme(dark = dark, wallpaperColors = wallpaper) { themes += SlatrixTheme.colors }
            }
        }
        compose.runOnIdle {
            for (colors in themes) for (background in DesignTokens.avatarColors) {
                val ratio = contrast(colors.onAvatar, background)
                assertTrue("Avatar initials need 4.5:1 contrast, got $ratio", ratio >= 4.5f)
            }
        }
    }

    private fun contrast(a: Color, b: Color): Float {
        val (light, dark) = listOf(a.luminance(), b.luminance()).sortedDescending()
        return (light + 0.05f) / (dark + 0.05f)
    }
}
