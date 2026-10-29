package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.ui.account.LiveProfileScreen
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.ComponentActivity
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.assertIsSelected
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
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class LiveProfileScreenTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun anAccountCanChooseDarkModeFromPreferences() {
        val mode = mutableStateOf<Boolean?>(null)
        compose.setContent {
            SlatrixTheme(dark = mode.value ?: false) {
                LiveProfileScreen("@alex:example.org", mode.value ?: false, mode.value, SidebarPalette.Aubergine,
                    { mode.value = it }, {}, {})
            }
        }
        compose.onNodeWithText("Preferences").performClick()
        compose.onNodeWithText("System default").assertExists()
        compose.onNodeWithText("Color mode").performClick()
        compose.onNodeWithText("Dark").performClick()
        compose.runOnIdle { assertEquals(true, mode.value) }
        compose.onNodeWithText("Dark").assertExists()
    }

    @Test fun anAccountCanChooseItsPaletteAndReturnToItsIdentity() {
        val palette = mutableStateOf(SidebarPalette.Aubergine)
        var returned = false
        compose.setContent {
            SlatrixTheme(palette = palette.value) {
                LiveProfileScreen("@alex:example.org", false, null, palette.value,
                    {}, { palette.value = it }, { returned = true })
            }
        }
        compose.onNodeWithText("@alex:example.org").assertExists()
        compose.onNodeWithText("Preferences").performClick()
        compose.onNodeWithText("Aubergine").assertIsSelected()
        compose.onNodeWithText("Lagoon").performScrollTo().performClick().assertIsSelected()
        compose.runOnIdle { assertEquals(SidebarPalette.Lagoon, palette.value) }
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("alex").assertExists()
        compose.onNodeWithText("@alex:example.org").assertExists()
        compose.runOnIdle { assertEquals(false, returned) }
        compose.onNodeWithContentDescription("Back").performClick()
        compose.runOnIdle { assertEquals(true, returned) }
    }
}
