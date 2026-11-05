package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ChannelDetailsActions
import ai.nuanu.slatrix.ui.account.ChannelDetailsScreen
import ai.nuanu.slatrix.ui.account.LivePreferencesScreen
import ai.nuanu.slatrix.ui.account.MessageActions
import ai.nuanu.slatrix.ui.account.MessageActionsHost
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.activity.BackEventCompat
import androidx.activity.OnBackPressedDispatcher
import androidx.activity.compose.LocalOnBackPressedDispatcherOwner
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNotEquals
import org.junit.Rule
import ai.nuanu.slatrix.ui.account.LiveWorkspace
import ai.nuanu.slatrix.ui.account.WorkspaceCover
import androidx.compose.material3.Text
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Panes and overlays ease in over 120–150 ms, as AGENTS.md sets for both apps; everything else is instant. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class MotionTest {
    @get:Rule val compose = createComposeRule()

    @Test fun aPushedPageEasesInAndSettlesWithin150Milliseconds() {
        var shown by mutableStateOf(false)
        compose.setContent {
            SlatrixTheme {
                LiveWorkspace(listOfNotNull(WorkspaceCover("preferences") { LivePreferencesScreen(false, null, false, {}, {}, {}) }.takeIf { shown })) {
                    Text("You")
                }
            }
        }
        settles("Color mode") { shown = true }
    }

    @Test fun aMessageMenuEasesInAndSettlesWithin150Milliseconds() {
        val message = ConversationMessage("a", "\$a", "@mira:example.org", "Mira", "Ship it", null, 1_700_000_000_000L,
            MessageKind.Text, MessageSendState.Sent, false, "M", 0)
        var shown by mutableStateOf(false)
        compose.setContent {
            SlatrixTheme { if (shown) MessageActionsHost(message, MessageActions(), null, {}, {}) {} }
        }
        settles("Copy text") { shown = true }
    }

    @Test fun aConversationSlidesInOverHomeAndBackIsInstant() {
        var open by mutableStateOf(false)
        compose.setContent {
            SlatrixTheme { LiveWorkspace(listOfNotNull(WorkspaceCover("design") { Text("Conversation") }.takeIf { open })) { Text("Home") } }
        }
        settles("Conversation") { open = true }
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { open = false; Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Conversation").assertDoesNotExist()
        compose.onNodeWithText("Home").assertExists()
    }

    @Test fun whileAConversationSlidesInWhatItCoversStaysUnderIt() {
        var open by mutableStateOf(false)
        compose.setContent {
            SlatrixTheme { LiveWorkspace(listOfNotNull(WorkspaceCover("design") { Text("Conversation") }.takeIf { open })) { Text("Home") } }
        }
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { open = true; Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Home").assertExists()
        compose.mainClock.advanceTimeBy(2_000)
        compose.onNodeWithText("Home").assertDoesNotExist()
    }

    // Pinned messages showed the conversation and its header for a moment, under a page fading in over nothing.
    @Test fun aPageFromChannelDetailsSlidesInOverTheDetails() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        compose.setContent { SlatrixTheme { ChannelDetailsScreen(room, null, ChannelDetailsActions(), {}, {}) {} } }
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        compose.onNodeWithText("Members").performSemanticsAction(SemanticsActions.OnClick)
        compose.runOnUiThread { Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Channel details").assertExists()
        compose.mainClock.advanceTimeBy(2_000)
        compose.onNodeWithText("Channel details").assertDoesNotExist()
    }

    @Test fun goingBackToAPageIsInstant() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        compose.setContent { SlatrixTheme { ChannelDetailsScreen(room, null, ChannelDetailsActions(), {}, {}) {} } }
        compose.onNodeWithText("Members").performClick()
        compose.waitForIdle()
        // Every pushed page's title sits in the same place in its bar.
        val title = bounds("Members").left
        compose.mainClock.autoAdvance = false
        // As a semantics action, since a tap's own events need the clock this holds.
        compose.onNodeWithContentDescription("Back").performSemanticsAction(SemanticsActions.OnClick)
        compose.runOnUiThread { Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        assertEquals("The details are back in place at once", title, bounds("Channel details").left)
    }

    // capability: app.predictive-back
    @Test fun aPageFollowsBackAsItsSwipedAndGoesOnlyOnRelease() {
        var went = false
        lateinit var dispatcher: OnBackPressedDispatcher
        compose.setContent {
            dispatcher = LocalOnBackPressedDispatcherOwner.current!!.onBackPressedDispatcher
            SlatrixTheme { LivePreferencesScreen(false, null, false, {}, {}, { went = true }) }
        }
        compose.waitForIdle()
        val rest = bounds("Color mode")
        compose.runOnUiThread {
            dispatcher.dispatchOnBackStarted(BackEventCompat(0f, 800f, 0f, BackEventCompat.EDGE_LEFT))
            dispatcher.dispatchOnBackProgressed(BackEventCompat(300f, 800f, 0.5f, BackEventCompat.EDGE_LEFT))
        }
        compose.waitForIdle()
        assertTrue("The page moves with the swipe", bounds("Color mode").left > rest.left)
        assertFalse("It stays until the swipe is let go", went)

        compose.runOnUiThread { dispatcher.dispatchOnBackCancelled() }
        compose.waitForIdle()
        assertEquals("A swipe taken back returns the page", rest, bounds("Color mode"))

        compose.runOnUiThread {
            dispatcher.dispatchOnBackStarted(BackEventCompat(0f, 800f, 0f, BackEventCompat.EDGE_LEFT))
            dispatcher.onBackPressed()
        }
        compose.runOnIdle { assertTrue(went) }
    }

    /** After [show], [text] is still on its way in two frames later, and in place, as it stays, 150 ms after that. */
    private fun settles(text: String, show: () -> Unit) {
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { show(); Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        val early = bounds(text)
        // From its first frame on screen: a sheet's window lays out a frame later than a page.
        compose.mainClock.advanceTimeBy(150)
        val settled = bounds(text)
        compose.mainClock.advanceTimeBy(2_000)
        assertNotEquals("It eases in rather than appearing in place", settled, early)
        assertEquals("It has settled by 150 ms", settled, bounds(text))
    }

    private fun bounds(text: String): Rect = compose.onNodeWithText(text).fetchSemanticsNode().boundsInRoot
}
