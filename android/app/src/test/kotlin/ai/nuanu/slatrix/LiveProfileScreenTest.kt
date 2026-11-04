package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.core.AppearancePreferences
import ai.nuanu.slatrix.ui.account.LivePreferencesScreen
import ai.nuanu.slatrix.ui.account.MessagePreview
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.TextUnit
import org.junit.Assert.assertTrue
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

    // capability: app.text-size
    @Test fun theTextSizeSliderGrowsMessageTextAndNothingElse() {
        val scale = mutableStateOf(1f)
        compose.setContent {
            SlatrixTheme(messageScale = scale.value) {
                LivePreferencesScreen(false, null, false, {}, {}, {}, messageScale = scale.value, onMessageScale = { scale.value = it })
            }
        }
        val preview = fontSize(MessagePreview)
        val label = fontSize("Color mode")
        compose.onNodeWithContentDescription("Message text size").performScrollTo()
            .performSemanticsAction(SemanticsActions.SetProgress) { it(AppearancePreferences.MessageScales.lastIndex.toFloat()) }
        compose.runOnIdle { assertEquals(AppearancePreferences.MessageScales.last(), scale.value) }
        assertTrue("The preview grows", fontSize(MessagePreview) > preview)
        assertEquals("The rest of the app keeps its size", label, fontSize("Color mode"))
    }

    private fun fontSize(text: String): TextUnit {
        val layout = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText(text).fetchSemanticsNode().config[SemanticsActions.GetTextLayoutResult].action!!(layout)
        return layout.single().layoutInput.style.fontSize
    }
}
