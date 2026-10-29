package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.LatestMessage
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.MessageSearchQuery
import ai.nuanu.slatrix.core.MessageSearchState
import ai.nuanu.slatrix.core.NotifyAbout
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SearchHit
import ai.nuanu.slatrix.core.SpaceSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.LivePreferencesScreen
import ai.nuanu.slatrix.ui.account.LiveYouScreen
import ai.nuanu.slatrix.ui.account.NotificationRows
import ai.nuanu.slatrix.ui.account.SearchScreen
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import com.github.takahirom.roborazzi.captureScreenRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Renders the connected Home and DMs tabs and the You page with fictional rooms for visual review, at the size of the
 * Slack reference captures (1080×2400 at 420 dpi) and between bands the height of that phone's system bars, so each
 * render can sit next to its reference.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
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
            RoomSummary("!design:example.org", "design", false, "", UnreadBadge.Count("1"), "D", 0, spaceIds = setOf(Harbor)),
            RoomSummary("!general:example.org", "general", false, "", UnreadBadge.None, "G", 2, spaceIds = setOf(Harbor)),
            RoomSummary("!plans:example.org", "launch-plans", false, "", UnreadBadge.None, "L", 5, isPrivate = true, spaceIds = setOf(Harbor)),
        )
        val spaces = listOf(SpaceSummary(Harbor, "Harbor"), SpaceSummary("!studio:example.org", "Studio Nine"))
        val query = MessageSearchQuery("release")
        val hits = MessageSearchState(query, listOf(
            SearchHit("!design:example.org", "\$1", "@wanda:example.org", "Wanda Moss", "The release notes are in the doc, comments welcome", now - hour),
            SearchHit("!wm:example.org", "\$2", "@wanda:example.org", "Wanda Moss", "Can you look at the release notes before lunch?", now - 2 * hour),
            SearchHit("!general:example.org", "\$3", "@dev:example.org", "Dev Singh", "Release train leaves on Thursday", now - 50 * hour),
        ))
        compose.setContent {
            SlatrixTheme(dark = dark, palette = palette) {
                val colors = SlatrixTheme.colors
                Column {
                    Box(Modifier.fillMaxWidth().height(StatusBar).background(if (tab in Pushed) colors.canvas else colors.workspaceBar))
                    Box(Modifier.weight(1f)) {
                        if (tab == "You") LiveYouScreen("@alex:example.org", { "Alex Doe" }, {}, {}, {})
                        else if (tab == "Preferences") LivePreferencesScreen(dark, null, palette, {}, {}, {}) {
                            NotificationRows(NotifyAbout.DirectAndMentions, true, null, {}, {})
                        }
                        else LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spaces = spaces, spacesKnown = true),
                            {}, {}, {}, Harbor, onBrowseChannels = {}, onCreateChannel = {},
                            search = { SearchScreen(rooms, "@alex:example.org", hits, {}, {}, {}, listOf("release notes", "offsite photos", "budget in:#design"), onRoom = {}) })
                    }
                    Box(Modifier.fillMaxWidth().height(GestureBar).background(if (tab in Pushed) colors.canvas else colors.raised))
                }
            }
        }
        when (tab) {
            "DMs" -> compose.onNode(hasText(tab) and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected)).performClick()
            "Switcher" -> compose.onNodeWithContentDescription("Switch workspace").performClick()
            "Sheet" -> compose.onNodeWithText("general").performTouchInput { longClick() }
            "Recent" -> compose.onNode(hasText("Search") and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected)).performClick()
            "AddChannel" -> compose.onNodeWithText("Add channel").performClick()
            "Search", "SearchResults" -> {
                compose.onNode(hasText("Search") and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected)).performClick()
                compose.onNode(hasSetTextAction()).performTextInput(if (tab == "Search") "d" else "release")
                if (tab == "SearchResults") compose.onNode(hasSetTextAction()).performImeAction()
            }
        }
        val theme = if (dark) "dark" else "light"
        compose.waitForIdle()
        captureScreenRoboImage("build/outputs/roborazzi/Live-$tab-$theme-${palette.tokenName}.png")
    }

    companion object {
        /** The reference phone's bars: 128 px and 63 px at 420 dpi. */
        private val StatusBar = 48.8.dp
        private val GestureBar = 24.dp
        private val Pushed = setOf("You", "Preferences")
        private const val Harbor = "!harbor:example.org"

        @JvmStatic @Parameters(name = "{0}-{1}-{2}")
        fun cases(): List<Array<Any>> = buildList {
            for (tab in listOf("Home", "DMs", "You", "Preferences", "Switcher", "Sheet", "AddChannel", "Recent", "Search", "SearchResults")) for (dark in listOf(false, true)) add(arrayOf(tab, dark, SidebarPalette.Aubergine))
            add(arrayOf("Home", false, SidebarPalette.Lagoon))
        }
    }
}
