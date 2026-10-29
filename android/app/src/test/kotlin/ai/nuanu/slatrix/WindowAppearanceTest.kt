package ai.nuanu.slatrix

import android.app.Application
import android.view.WindowInsetsController
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
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

    @Test fun darkModeSwitchUpdatesSystemBarIcons() {
        val lightBars = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
            WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
        compose.runOnIdle {
            assertEquals(lightBars, compose.activity.window.insetsController!!.systemBarsAppearance and lightBars)
        }
        compose.onNodeWithContentDescription("You").performClick()
        compose.onNodeWithText("Preferences").performClick()
        compose.onNodeWithText("Dark mode").performScrollTo().performClick().assertIsOn()
        compose.runOnIdle {
            assertEquals(0, compose.activity.window.insetsController!!.systemBarsAppearance and lightBars)
        }
    }
}
