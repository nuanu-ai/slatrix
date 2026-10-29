package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.ui.mockups.SlatrixMockups
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import android.view.WindowInsetsController
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-notnight-420dpi")
class WindowAppearanceTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val lightBars = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
        WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS

    @Test fun followsSystemLightUntilDarkIsChosen() = checkAppearance(lightBars, "Dark", 0)

    @Test @Config(qualifiers = "w412dp-h892dp-night-420dpi")
    fun followsSystemDarkUntilLightIsChosen() = checkAppearance(0, "Light", lightBars)

    private fun checkAppearance(initialBars: Int, choice: String, chosenBars: Int) {
        compose.activity.setContent { SlatrixMockups(dark = isSystemInDarkTheme()) }
        compose.runOnIdle {
            assertEquals(initialBars, compose.activity.window.insetsController!!.systemBarsAppearance and lightBars)
        }
        compose.onNodeWithContentDescription("You").performClick()
        compose.onNodeWithText("Preferences").performClick()
        compose.onNodeWithText("System default").assertExists()
        compose.onNodeWithText("Color mode").performClick()
        compose.onNode(hasText(choice) and hasAnyAncestor(isDialog())).performClick()
        compose.runOnIdle {
            assertEquals(chosenBars, compose.activity.window.insetsController!!.systemBarsAppearance and lightBars)
        }
    }
}
