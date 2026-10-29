package ai.nuanu.slatrix

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
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
            compose.onNodeWithText("All conversations", useUnmergedTree = true).assertReadable()
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
            tab("Home").performClick()
            compose.onNodeWithText("Home", useUnmergedTree = true).assertReadable()
            tab("DMs").performClick()
            compose.onNodeWithText("Direct messages").assertExists()
            compose.onNodeWithText("DMs", useUnmergedTree = true).assertReadable()
        }
    }

    @Test fun unreadCountsStayReadableOnTheMentionBadgeInBothThemes() {
        val dark = mutableStateOf(false)
        val rooms = RoomListState(listOf(RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.Count("3"), "T", 0)), loading = false)
        compose.setContent { SlatrixTheme(dark = dark.value) { LiveHomeScreen("@alex:example.org", rooms, {}, {}, {}) } }
        for (isDark in listOf(false, true)) {
            compose.runOnIdle { dark.value = isDark }
            compose.onNodeWithText("3", useUnmergedTree = true).assertReadable()
        }
    }

    private fun tab(label: String) =
        compose.onNode(hasText(label) and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected))

    /** Compares the text's resolved color with the color drawn most inside its bounds, which is its background. */
    private fun SemanticsNodeInteraction.assertReadable() {
        var foreground = Color.Unspecified
        performSemanticsAction(SemanticsActions.GetTextLayoutResult) { action ->
            val layouts = mutableListOf<TextLayoutResult>()
            assertTrue("Rendered text must expose its resolved style", action(layouts))
            foreground = layouts.single().layoutInput.style.color
        }
        val bounds = fetchSemanticsNode().boundsInWindow
        compose.runOnIdle {
            val window = compose.activity.window.decorView
            val bitmap = Bitmap.createBitmap(window.width, window.height, Bitmap.Config.ARGB_8888)
            window.draw(Canvas(bitmap))
            val width = bounds.width.toInt()
            val height = bounds.height.toInt()
            val pixels = IntArray(width * height)
            bitmap.getPixels(pixels, 0, width, bounds.left.toInt(), bounds.top.toInt(), width, height)
            val background = Color(pixels.groupBy { it }.maxBy { it.value.size }.key).luminance()
            val text = foreground.luminance()
            val contrast = (maxOf(text, background) + 0.05f) / (minOf(text, background) + 0.05f)
            assertTrue("Rendered label needs 4.5:1 contrast, got $contrast", contrast >= 4.5f)
        }
    }
}
