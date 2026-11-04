package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.LivePreferencesScreen
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

    // capability: app.appearance
    @Test fun anAccountCanChooseDarkModeFromPreferences() {
        val mode = mutableStateOf<Boolean?>(null)
        compose.setContent {
            SlatrixTheme(dark = mode.value ?: false) {
                LivePreferencesScreen(mode.value ?: false, mode.value, false, { mode.value = it }, {}, {})
            }
        }
        compose.onNodeWithText("System default").assertExists()
        compose.onNodeWithText("Color mode").performClick()
        compose.onNodeWithText("Dark").performClick()
        compose.runOnIdle { assertEquals(true, mode.value) }
        compose.onNodeWithText("Dark").assertExists()
    }

    // capability: app.appearance
    @Test fun anAccountCanTakeItsColorsFromTheWallpaperAndGoBack() {
        val wallpaper = mutableStateOf(false)
        var returned = false
        compose.setContent {
            SlatrixTheme(wallpaperColors = wallpaper.value) {
                LivePreferencesScreen(false, null, wallpaper.value, {}, { wallpaper.value = it }, { returned = true })
            }
        }
        compose.onNodeWithText("Slatrix").assertIsSelected()
        compose.onNodeWithText("From your wallpaper").performScrollTo().performClick().assertIsSelected()
        compose.runOnIdle { assertEquals(true, wallpaper.value) }
        compose.onNodeWithContentDescription("Back").performClick()
        compose.runOnIdle { assertEquals(true, returned) }
    }
}
