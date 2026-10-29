package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.LatestMessage
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SpaceSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.LiveYouScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Renders Home, DMs and You at the size of the Slack reference captures (1080×2400 at 420 dpi), under a band the height
 * of that phone's status bar and over one the height of its gesture bar, so each render can sit next to its reference.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class ParityScreenshots(private val screen: String) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        val day = 86_400_000L
        val now = System.currentTimeMillis()
        val rooms = listOf(
            RoomSummary("!jo:example.org", "Jordan Lee", true, "", UnreadBadge.None, "JL", 2,
                latest = LatestMessage("Sounds good, see you then", now - 7 * day, own = true)),
            RoomSummary("!ma:example.org", "Maya Torres", true, "", UnreadBadge.None, "MT", 5,
                latest = LatestMessage("Here are the notes from yesterday’s review, with the open questions at the end", now - 10 * day, own = true)),
            RoomSummary("!al:example.org", "Alex Doe", true, "", UnreadBadge.None, "AD", 0),
            RoomSummary("!plans:example.org", "launch-plans", false, "", UnreadBadge.None, "L", 1, isPrivate = true, spaceIds = setOf("!studio:example.org")),
        )
        compose.setContent {
            SlatrixTheme(dark = false) {
                val colors = SlatrixTheme.colors
                Column {
                    Box(Modifier.fillMaxWidth().height(StatusBar).background(if (screen == "you") colors.canvas else colors.workspaceBar))
                    Box(Modifier.weight(1f)) {
                        if (screen == "you") LiveYouScreen("@alex:example.org", { "Alex Doe" }, {}, {}, {})
                        else LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true,
                            spaces = listOf(SpaceSummary("!studio:example.org", "Studio"))), {}, {}, {}, "!studio:example.org")
                    }
                    Box(Modifier.fillMaxWidth().height(NavigationBar).background(if (screen == "you") colors.canvas else colors.raised))
                }
            }
        }
        if (screen == "dms") compose.onNode(hasText("DMs") and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected)).performClick()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/parity-$screen.png")
    }

    companion object {
        /** The reference phone's status bar: 128 px at 420 dpi. */
        private val StatusBar = 48.8.dp
        /** Its gesture bar: 63 px. */
        private val NavigationBar = 24.dp

        @JvmStatic @Parameters(name = "{0}")
        fun cases(): List<Array<Any>> = listOf("home", "dms", "you").map { arrayOf(it) }
    }
}
