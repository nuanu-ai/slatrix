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
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
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
import org.junit.Assert.assertNotEquals
import org.junit.Rule
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
            SlatrixTheme { if (shown) LivePreferencesScreen(false, null, SidebarPalette.Aubergine, {}, {}, {}) }
        }
        settles("Color mode") { shown = true }
    }

    @Test fun aBottomSheetEasesInAndSettlesWithin150Milliseconds() {
        val message = ConversationMessage("a", "\$a", "@mira:example.org", "Mira", "Ship it", null, 1_700_000_000_000L,
            MessageKind.Text, MessageSendState.Sent, false, "M", 0)
        var shown by mutableStateOf(false)
        compose.setContent {
            SlatrixTheme { if (shown) MessageActionsHost(message, MessageActions(), null, {}, {}) {} }
        }
        settles("Copy message") { shown = true }
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

    /** After [show], [text] is still on its way in two frames later, and in place, as it stays, 150 ms after that. */
    private fun settles(text: String, show: () -> Unit) {
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { show(); Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        val early = bounds(text)
        compose.mainClock.advanceTimeBy(150)
        val settled = bounds(text)
        compose.mainClock.advanceTimeBy(2_000)
        assertNotEquals("It eases in rather than appearing in place", settled, early)
        assertEquals("It has settled by 150 ms", settled, bounds(text))
    }

    private fun bounds(text: String): Rect = compose.onNodeWithText(text).fetchSemanticsNode().boundsInRoot
}
