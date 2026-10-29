package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.LatestMessage
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.LiveYouScreen
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Renders the connected Home and DMs tabs and the You page with fictional rooms for visual review. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class LiveScreenshots(private val tab: String, private val dark: Boolean, private val palette: SidebarPalette) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        val hour = 3_600_000L
        val now = System.currentTimeMillis()
        val rooms = listOf(
            RoomSummary("!wm:example.org", "Wanda Moss", true, "", UnreadBadge.Count("2"), "WM", 1,
                latest = LatestMessage("Can you look at the release notes before lunch?", now - hour, own = false)),
            RoomSummary("!n:example.org", "Nina", true, "", UnreadBadge.None, "N", 3,
                latest = LatestMessage("Thanks, merged.", now - 30 * hour, own = true)),
            RoomSummary("!ds:example.org", "Dev Singh", true, "", UnreadBadge.Bold, "DS", 4,
                latest = LatestMessage("Photos from the offsite are in the shared folder, have a look when you get a minute", now - 400 * hour, own = false)),
            RoomSummary("!design:example.org", "design", false, "", UnreadBadge.Count("1"), "D", 0),
            RoomSummary("!general:example.org", "general", false, "", UnreadBadge.None, "G", 2),
        )
        compose.setContent {
            SlatrixTheme(dark = dark, palette = palette) {
                if (tab == "You") LiveYouScreen("@alex:example.org", {}, {}, {})
                else LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {})
            }
        }
        if (tab == "DMs") compose.onNode(hasText(tab) and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected)).performClick()
        val theme = if (dark) "dark" else "light"
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/Live-$tab-$theme-${palette.tokenName}.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "{0}-{1}-{2}")
        fun cases(): List<Array<Any>> = buildList {
            for (tab in listOf("Home", "DMs", "You")) for (dark in listOf(false, true)) add(arrayOf(tab, dark, SidebarPalette.Aubergine))
            add(arrayOf("Home", false, SidebarPalette.Lagoon))
        }
    }
}
