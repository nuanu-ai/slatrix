package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.ComponentActivity
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
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
class BadgeContrastTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun unreadCountsRemainReadableOnTheMentionBadgeInBothThemes() {
        val dark = mutableStateOf(false)
        val rooms = RoomListState(listOf(RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.Count("3"), "T", 0)), loading = false)
        compose.setContent { SlatrixTheme(dark = dark.value) { LiveHomeScreen("@alex:example.org", rooms, {}, {}, {}) } }
        for (isDark in listOf(false, true)) {
            compose.runOnIdle { dark.value = isDark }
            compose.onNodeWithText("3", useUnmergedTree = true).performSemanticsAction(SemanticsActions.GetTextLayoutResult) { action ->
                val layouts = mutableListOf<TextLayoutResult>()
                action(layouts)
                val foreground = layouts.single().layoutInput.style.color.luminance()
                val background = DesignTokens.colors(isDark, SidebarPalette.Aubergine).getValue("mention").luminance()
                val contrast = (maxOf(foreground, background) + 0.05f) / (minOf(foreground, background) + 0.05f)
                assertTrue("Unread count needs 4.5:1 contrast in ${if (isDark) "dark" else "light"} theme, got $contrast", contrast >= 4.5f)
            }
        }
    }
}
