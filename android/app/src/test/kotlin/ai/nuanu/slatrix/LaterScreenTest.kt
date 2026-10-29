package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SavedMessage
import ai.nuanu.slatrix.core.SavedPreview
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LaterScreen
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class LaterScreenTest {
    @get:Rule val compose = createComposeRule()
    private val rooms = listOf(RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0),
        RoomSummary("!general:example.org", "general", false, "", UnreadBadge.None, "G", 1))

    // capability: message.save
    @Test fun laterListsSavedMessagesNewestFirstOpensOneAndRemovesOne() {
        val saved = listOf(SavedMessage("!general:example.org", "\$one", 1_000), SavedMessage("!design:example.org", "\$two", 2_000))
        val previews = mapOf("\$two" to SavedPreview("Mira Chen", "Ship it on Thursday", 1_700_000_000_000L),
            "\$one" to SavedPreview("Sam Okafor", "Budget is in the doc", 1_700_000_000_000L))
        val opened = mutableListOf<String>()
        val removed = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme { LaterScreen(saved, rooms, { previews[it.eventId] }, { opened += it.eventId }, { removed += it.eventId }) {} }
        }
        compose.onNodeWithText("Ship it on Thursday").assertIsDisplayed()
        val first = compose.onNodeWithText("Ship it on Thursday").fetchSemanticsNode().boundsInRoot.top
        assertTrue(first < compose.onNodeWithText("Budget is in the doc").fetchSemanticsNode().boundsInRoot.top)
        compose.onNodeWithText("#design").assertIsDisplayed()

        compose.onNodeWithText("Ship it on Thursday").performClick()
        compose.onAllNodesWithContentDescription("Remove from Later")[1].performClick()
        compose.runOnIdle {
            assertEquals(listOf("\$two"), opened)
            assertEquals(listOf("\$one"), removed)
        }
    }

    @Test fun nothingSavedSaysSo() {
        compose.setContent { SlatrixTheme { LaterScreen(emptyList(), rooms, { null }, {}, {}) {} } }
        compose.onNodeWithText("Nothing saved for later").assertIsDisplayed()
    }

    // capability: message.save
    @Test fun homesLaterCardCountsWhatIsSavedAndOpensIt() {
        var opened = false
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {},
                    laterCount = 2, onLater = { opened = true })
            }
        }
        compose.onNodeWithText("2 items").assertIsDisplayed()
        compose.onNodeWithText("Later").performClick()
        compose.runOnIdle { assertTrue(opened) }
    }
}
