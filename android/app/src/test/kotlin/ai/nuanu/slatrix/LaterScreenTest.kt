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
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.test.swipeRight
import androidx.compose.ui.test.swipe
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import org.junit.Assert.assertFalse
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
    @Config(qualifiers = "w320dp-h704dp-xxxhdpi")
    @Test fun onANarrowPhoneTheSendersNameKeepsItsRoomAndTheTimeGivesWay() {
        val name = "Alexandra Whitfield"
        compose.setContent {
            SlatrixTheme {
                LaterScreen(listOf(SavedMessage("!design:example.org", "\$one", 1_000)), rooms,
                    { SavedPreview("@alexandra:example.org", name, "Ship it on Thursday", 1_700_000_000_000L) }, {}, {})
            }
        }
        val layouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText(name, useUnmergedTree = true).performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertFalse(layouts.single().isLineEllipsized(0))
    }

    // capability: message.save
    @Test fun laterListsSavedMessagesNewestFirstOpensOneAndRemovesOne() {
        val saved = listOf(SavedMessage("!general:example.org", "\$one", 1_000), SavedMessage("!design:example.org", "\$two", 2_000))
        val previews = mapOf("\$two" to SavedPreview("@mira:example.org", "Mira Chen", "Ship it on Thursday", 1_700_000_000_000L),
            "\$one" to SavedPreview("@sam:example.org", "Sam Okafor", "Budget is in the doc", 1_700_000_000_000L))
        val opened = mutableListOf<String>()
        val removed = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme { LaterScreen(saved, rooms, { previews[it.eventId] }, { opened += it.eventId }, { removed += it.eventId }) }
        }
        compose.onNodeWithText("Ship it on Thursday").assertIsDisplayed()
        val first = compose.onNodeWithText("Ship it on Thursday").fetchSemanticsNode().boundsInRoot.top
        assertTrue(first < compose.onNodeWithText("Budget is in the doc").fetchSemanticsNode().boundsInRoot.top)
        compose.onNodeWithText("#design").assertIsDisplayed()
        compose.onNodeWithText("MC", useUnmergedTree = true).assertIsDisplayed()

        compose.onNodeWithText("Ship it on Thursday").performClick()
        compose.onAllNodesWithContentDescription("Remove from Later")[1].performClick()
        compose.onNodeWithText("Undo").assertIsDisplayed()
        compose.waitUntil(10_000) { removed.isNotEmpty() }
        assertEquals(listOf("\$two"), opened)
        assertEquals(listOf("\$one"), removed)
    }

    @Test fun aSaveTimeMergedFromAnotherDeviceKeepsTheCardAsItShows() {
        var saved by mutableStateOf(listOf(SavedMessage("!design:example.org", "\$one", 1_000)))
        var reads = 0
        // Only the first read finds the message, so a card read again would say it's unavailable.
        val load: suspend (SavedMessage) -> SavedPreview? = { if (reads++ == 0) SavedPreview("@mira:example.org", "Mira Chen", "Ship it on Thursday", 1_700_000_000_000L) else null }
        compose.setContent { SlatrixTheme { LaterScreen(saved, rooms, load, {}, {}) } }
        compose.onNodeWithText("Ship it on Thursday").assertIsDisplayed()

        saved = listOf(SavedMessage("!design:example.org", "\$one", 2_000))
        compose.waitForIdle()
        compose.onNodeWithText("Ship it on Thursday").assertIsDisplayed()
    }

    @Test fun nothingSavedSaysSo() {
        compose.setContent { SlatrixTheme { LaterScreen(emptyList(), rooms, { null }, {}, {}) } }
        compose.onNodeWithText("Nothing saved for later").assertIsDisplayed()
    }

    @Test fun homesLaterTabShowsWhatIsSaved() {
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {},
                    later = { Text("Saved list") })
            }
        }
        compose.onNodeWithText("Later").performClick()
        compose.onNodeWithText("Saved list").assertIsDisplayed()
    }

    @Test fun aSwipeLeftMarksACardDoneWithAnUndoAndLeavesTheTabAsItIs() {
        val saved = listOf(SavedMessage("!design:example.org", "\$one", 1_000))
        val removed = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {},
                    later = { LaterScreen(saved, rooms, { SavedPreview("@sam:example.org", "Sam", "Ship the draft", 1_000) }, {}, { removed += it.eventId }) })
            }
        }
        tab("Later").performClick()
        compose.onNodeWithText("Ship the draft").performTouchInput { swipeLeft() }
        compose.onNodeWithText("Marked as done").assertIsDisplayed()
        compose.onNodeWithText("Ship the draft").assertDoesNotExist()
        compose.onNodeWithText("Undo").performClick()
        compose.onNodeWithText("Ship the draft").assertIsDisplayed()
        compose.onNodeWithText("Marked as done").assertDoesNotExist()
        assertEquals(emptyList<String>(), removed)
        assertTrue(tab("Later").fetchSemanticsNode().config.getOrElse(SemanticsProperties.Selected) { false })

        compose.onNodeWithText("Ship the draft").performTouchInput { swipeLeft() }
        compose.waitUntil(10_000) { removed.isNotEmpty() }
        assertEquals(listOf("\$one"), removed)
        compose.onNodeWithText("Marked as done").assertDoesNotExist()
    }

    // capability: home.swipe-tabs
    @Test fun inLaterASwipeChangesTabsUnlessItStartsLeftOnACard() {
        val saved = listOf(SavedMessage("!design:example.org", "\$one", 1_000))
        val removed = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {},
                    later = { LaterScreen(saved, rooms, { SavedPreview("@sam:example.org", "Sam", "Ship the draft", 1_000) }, {}, { removed += it.eventId }) })
            }
        }
        tab("Later").performClick()
        compose.onNodeWithText("Ship the draft").performTouchInput { swipeRight() }
        compose.waitUntil { tab("DMs").fetchSemanticsNode().config.getOrElse(SemanticsProperties.Selected) { false } }

        tab("Later").performClick()
        compose.onNodeWithText("Ship the draft").assertIsDisplayed()
        // Below the only card, on the list's empty space.
        compose.onNode(SemanticsMatcher.keyIsDefined(SemanticsProperties.HorizontalScrollAxisRange)).performTouchInput {
            swipe(Offset(width * 0.9f, height * 0.6f), Offset(width * 0.1f, height * 0.6f))
        }
        compose.waitUntil { tab("Activity").fetchSemanticsNode().config.getOrElse(SemanticsProperties.Selected) { false } }
        compose.onNodeWithText("Marked as done").assertDoesNotExist()
        assertEquals(emptyList<String>(), removed)
    }

    private fun tab(label: String) =
        compose.onNode(hasText(label) and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected))
}
