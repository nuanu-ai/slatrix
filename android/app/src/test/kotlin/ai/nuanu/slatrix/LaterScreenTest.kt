package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SavedList
import ai.nuanu.slatrix.core.SavedMessage
import ai.nuanu.slatrix.core.SavedPreview
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LaterActions
import ai.nuanu.slatrix.ui.account.LaterScreen
import ai.nuanu.slatrix.core.LaterState
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
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
import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import androidx.compose.ui.graphics.Color
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.compose.ui.platform.LocalView
import kotlin.math.abs
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
                LaterScreen(SavedList(listOf(SavedMessage("!design:example.org", "\$one", 1_000))), rooms,
                    { SavedPreview("@alexandra:example.org", name, "Ship it on Thursday", 1_700_000_000_000L) }, LaterActions({}))
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
            SlatrixTheme {
                LaterScreen(SavedList.normalized(saved, emptyList()), rooms, { previews[it.eventId] },
                    LaterActions({ opened += it.eventId }, remove = { removed += it.eventId }))
            }
        }
        compose.onNodeWithText("Ship it on Thursday").assertIsDisplayed()
        val first = compose.onNodeWithText("Ship it on Thursday").fetchSemanticsNode().boundsInRoot.top
        assertTrue(first < compose.onNodeWithText("Budget is in the doc").fetchSemanticsNode().boundsInRoot.top)
        compose.onNodeWithText("#design").assertIsDisplayed()
        compose.onNodeWithText("MC", useUnmergedTree = true).assertIsDisplayed()

        compose.onNodeWithText("Ship it on Thursday").performClick()
        compose.onNodeWithText("Budget is in the doc").performTouchInput { longClick() }
        compose.onNodeWithText("Remove from Later").performClick()
        compose.onNodeWithText("Removed from Later").assertIsDisplayed()
        compose.waitUntil(10_000) { removed.isNotEmpty() }
        assertEquals(listOf("\$two"), opened)
        assertEquals(listOf("\$one"), removed)
    }

    // capability: later.complete
    // capability: later.archive
    @Test fun eachTabListsItsOwnAndAnArchivedMessageComesBackToInProgress() {
        val saved = SavedList(listOf(SavedMessage("!design:example.org", "\$open", 3_000),
            SavedMessage("!design:example.org", "\$done", 2_000, LaterState.COMPLETED),
            SavedMessage("!design:example.org", "\$kept", 1_000, LaterState.ARCHIVED)))
        val bodies = mapOf("\$open" to "Ship the draft", "\$done" to "Budget is in the doc", "\$kept" to "Old launch plan")
        val moved = mutableListOf<Pair<String, LaterState>>()
        compose.setContent {
            SlatrixTheme {
                LaterScreen(saved, rooms, { SavedPreview("@sam:example.org", "Sam", bodies.getValue(it.eventId), 1_000) },
                    LaterActions({}, move = { item, state -> moved += item.eventId to state }))
            }
        }
        compose.onNodeWithText("Ship the draft").assertIsDisplayed()
        compose.onNodeWithText("Budget is in the doc").assertDoesNotExist()
        compose.onNodeWithText("Completed").performClick()
        compose.onNodeWithText("Budget is in the doc").assertIsDisplayed()
        compose.onNodeWithText("Ship the draft").assertDoesNotExist()
        compose.onNodeWithText("Archived").performClick()
        compose.onNodeWithText("Old launch plan").assertIsDisplayed()
        compose.onNodeWithContentDescription("Move to In progress").performClick()
        compose.onNodeWithText("Moved to In progress").assertIsDisplayed()
        compose.waitUntil(10_000) { moved.isNotEmpty() }
        assertEquals(listOf("\$kept" to LaterState.IN_PROGRESS), moved)
    }

    // capability: later.remind
    @Test fun remindMeOffersSlacksChoicesAndAnOverdueReminderSaysSo() {
        val now = 1_761_955_200_000L
        val saved = SavedList(listOf(SavedMessage("!design:example.org", "\$one", 2_000),
            SavedMessage("!design:example.org", "\$late", 1_000, remindAt = now - 60_000)))
        val reminders = mutableListOf<Pair<String, Long?>>()
        compose.setContent {
            SlatrixTheme {
                LaterScreen(saved, rooms, { SavedPreview("@sam:example.org", "Sam", "Body ${it.eventId}", 1_000) },
                    LaterActions({}, remind = { item, at -> reminders += item.eventId to at }), now = { now })
            }
        }
        compose.onNodeWithText("Overdue").assertIsDisplayed()
        // An overdue reminder comes first.
        assertTrue(compose.onNodeWithText("Body \$late").fetchSemanticsNode().boundsInRoot.top <
            compose.onNodeWithText("Body \$one").fetchSemanticsNode().boundsInRoot.top)
        compose.onNodeWithText("Body \$one").performTouchInput { longClick() }
        compose.onNodeWithText("Remind me").performClick()
        compose.onNode(hasText("In 20 minutes", substring = true)).performClick()
        assertEquals(listOf("\$one" to now + 20 * 60_000), reminders)
    }

    @Test fun aSaveTimeMergedFromAnotherDeviceKeepsTheCardAsItShows() {
        var saved by mutableStateOf(listOf(SavedMessage("!design:example.org", "\$one", 1_000)))
        var reads = 0
        // Only the first read finds the message, so a card read again would say it's unavailable.
        val load: suspend (SavedMessage) -> SavedPreview? = { if (reads++ == 0) SavedPreview("@mira:example.org", "Mira Chen", "Ship it on Thursday", 1_700_000_000_000L) else null }
        compose.setContent { SlatrixTheme { LaterScreen(SavedList(saved), rooms, load, LaterActions({})) } }
        compose.onNodeWithText("Ship it on Thursday").assertIsDisplayed()

        saved = listOf(SavedMessage("!design:example.org", "\$one", 2_000))
        compose.waitForIdle()
        compose.onNodeWithText("Ship it on Thursday").assertIsDisplayed()
    }

    @Test fun nothingSavedSaysSo() {
        compose.setContent { SlatrixTheme { LaterScreen(SavedList(), rooms, { null }, LaterActions({})) } }
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

    // capability: later.complete
    @Test fun aSwipeLeftMarksACardCompleteWithAnUndoAndLeavesTheTabAsItIs() {
        val saved = SavedList(listOf(SavedMessage("!design:example.org", "\$one", 1_000)))
        val moved = mutableListOf<Pair<String, LaterState>>()
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {},
                    later = { LaterScreen(saved, rooms, { SavedPreview("@sam:example.org", "Sam", "Ship the draft", 1_000) },
                        LaterActions({}, move = { item, state -> moved += item.eventId to state })) })
            }
        }
        tab("Later").performClick()
        compose.onNodeWithText("Ship the draft").performTouchInput { swipeLeft() }
        compose.onNodeWithText("Marked as complete").assertIsDisplayed()
        compose.onNodeWithText("Ship the draft").assertDoesNotExist()
        compose.onNodeWithText("Undo").performClick()
        compose.onNodeWithText("Ship the draft").assertIsDisplayed()
        compose.onNodeWithText("Marked as complete").assertDoesNotExist()
        assertEquals(emptyList<Pair<String, LaterState>>(), moved)
        assertTrue(tab("Later").fetchSemanticsNode().config.getOrElse(SemanticsProperties.Selected) { false })

        compose.onNodeWithText("Ship the draft").performTouchInput { swipeLeft() }
        compose.waitUntil(10_000) { moved.isNotEmpty() }
        assertEquals(listOf("\$one" to LaterState.COMPLETED), moved)
        compose.onNodeWithText("Marked as complete").assertDoesNotExist()
    }

    // capability: home.swipe-tabs
    @Test fun inLaterASwipeChangesTabsUnlessItStartsLeftOnACard() {
        val saved = SavedList(listOf(SavedMessage("!design:example.org", "\$one", 1_000)))
        val removed = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {},
                    later = { LaterScreen(saved, rooms, { SavedPreview("@sam:example.org", "Sam", "Ship the draft", 1_000) }, LaterActions({}, move = { item, _ -> removed += item.eventId }, remove = { removed += it.eventId })) })
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
        compose.onNodeWithText("Marked as complete").assertDoesNotExist()
        assertEquals(emptyList<String>(), removed)
    }

    private fun tab(label: String) =
        compose.onNode(hasText(label) and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected))

    // capability: message.save
    @Test fun aSendersPictureHasTheColorTheirNameGivesThemEverywhereElse() {
        val name = "Sam Okafor"
        lateinit var view: View
        compose.setContent {
            view = LocalView.current
            SlatrixTheme {
                LaterScreen(SavedList(listOf(SavedMessage("!design:example.org", "\$one", 1_000))), rooms,
                    { SavedPreview("@sam:example.org", name, "Ship it on Thursday", 1_000) }, LaterActions({}))
            }
        }
        // Below the initials, where the tile's shading has reached the color itself.
        val initials = compose.onNodeWithText("SO", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        val picture = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
        val shown = Color(picture.getPixel(initials.center.x.toInt(), (initials.bottom + (initials.bottom - initials.top) / 4).toInt()))
        fun distance(color: Color) = abs(color.red - shown.red) + abs(color.green - shown.green) + abs(color.blue - shown.blue)
        assertEquals(AvatarPlaceholder.colorIndex(name), DesignTokens.avatarColors.indices.minBy { distance(DesignTokens.avatarColors[it]) })
    }
}
