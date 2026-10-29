package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.ComponentActivity
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class LiveForegroundTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun workspaceTitleInheritsReadableForegroundWhenAppearanceChanges() {
        val dark = mutableStateOf(false)
        val palette = mutableStateOf(SidebarPalette.Aubergine)
        compose.setContent {
            SlatrixTheme(dark = dark.value, palette = palette.value) {
                LiveHomeScreen("@alex:example.org", RoomListState(loading = false), {}, {}, {})
            }
        }
        for (isDark in listOf(false, true)) for (sidebar in SidebarPalette.entries) {
            compose.runOnIdle { dark.value = isDark; palette.value = sidebar }
            compose.onNodeWithText("All conversations", useUnmergedTree = true)
                .assertReadableOn(DesignTokens.colors(true, sidebar).getValue("frame"))
        }
    }

    @Test fun selectedPhoneDestinationsStayReadableAndNavigateInBothThemes() {
        val dark = mutableStateOf(false)
        val palette = mutableStateOf(SidebarPalette.Aubergine)
        compose.setContent {
            SlatrixTheme(dark = dark.value, palette = palette.value) {
                LiveHomeScreen("@alex:example.org", RoomListState(loading = false), {}, {}, {})
            }
        }
        for (isDark in listOf(false, true)) for (sidebar in SidebarPalette.entries) {
            compose.runOnIdle { dark.value = isDark; palette.value = sidebar }
            val canvas = DesignTokens.colors(isDark, sidebar).getValue("canvas")
            tab("Home").performClick()
            compose.onNodeWithText("Home", useUnmergedTree = true).assertReadableOn(canvas)
            tab("DMs").performClick()
            compose.onNodeWithText("Direct messages").assertExists()
            compose.onNodeWithText("DMs", useUnmergedTree = true).assertReadableOn(canvas)
            tab("You").performClick().assertIsSelected()
        }
    }

    private fun tab(label: String) =
        compose.onNode(hasText(label) and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected))

    private fun SemanticsNodeInteraction.assertReadableOn(background: Color) {
        performSemanticsAction(SemanticsActions.GetTextLayoutResult) { action ->
            val layouts = mutableListOf<TextLayoutResult>()
            assertTrue("Rendered text must expose its resolved style", action(layouts))
            val foreground = layouts.single().layoutInput.style.color.luminance()
            val backdrop = background.luminance()
            val contrast = (maxOf(foreground, backdrop) + 0.05f) / (minOf(foreground, backdrop) + 0.05f)
            assertTrue("Rendered label needs 4.5:1 contrast, got $contrast", contrast >= 4.5f)
        }
    }
}
