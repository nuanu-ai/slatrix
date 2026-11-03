package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ComposerActions
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
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
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class ThreadScreenTest {
    @get:Rule val compose = createComposeRule()

    // capability: thread.reply
    @Test fun aThreadShowsItsRootAboveItsRepliesAndRepliesFromItsOwnComposer() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        fun message(id: String, body: String, minutes: Int) = ConversationMessage(id, "\$$id", "@sam:example.org", "Sam", body,
            null, minutes * 60_000L, MessageKind.Text, MessageSendState.Sent, false, "S", 0)
        val rows = listOf(message("root", "Ship on Friday?", 0), message("a", "Yes, after QA", 1), message("b", "Agreed", 30))
        val draft = mutableStateOf(ComposerState(loading = false))
        var sent: String? = null
        var back = false
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(rows, loading = false, hasMore = false), draft.value,
                    { draft.value = draft.value.copy(text = it) }, { sent = draft.value.text }, { back = true },
                    {}, {}, {}, {}, {}, threadRoot = "\$root")
            }
        }

        compose.onNodeWithText("Thread").assertExists()
        compose.onNodeWithText("#design").assertExists()
        compose.onNodeWithText("2 replies").assertExists()
        compose.onNodeWithText("This is the very beginning", substring = true).assertDoesNotExist()
        val root = compose.onNodeWithText("Ship on Friday?").getUnclippedBoundsInRoot()
        val reply = compose.onNodeWithText("Yes, after QA").getUnclippedBoundsInRoot()
        assertTrue("The root tops the thread", root.bottom <= reply.top)

        compose.onNodeWithContentDescription("Add a reply").performTextReplacement("Shipping it")
        compose.onNodeWithContentDescription("Send message").performClick()
        compose.runOnIdle { assertEquals("Shipping it", sent) }
        compose.onNodeWithContentDescription("Back").performClick()
        compose.runOnIdle { assertTrue(back) }
    }

    // capability: thread.send-to-channel
    @Test fun theThreadComposerOffersToAlsoSendTheReplyToItsChannel() {
        val channel = RoomSummary("!ops:example.org", "ops", false, "", UnreadBadge.None, "O", 0, isPrivate = true)
        val root = ConversationMessage("root", "\$root", "@sam:example.org", "Sam", "Ship on Friday?", null, 0L, MessageKind.Text,
            MessageSendState.Sent, false, "S", 0)
        val room = mutableStateOf(channel)
        val draft = mutableStateOf(ComposerState(loading = false))
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room.value, ConversationState(listOf(root), loading = false, hasMore = false), draft.value,
                    { draft.value = draft.value.copy(text = it) }, {}, {}, {}, {}, {}, {}, {}, threadRoot = "\$root",
                    composerActions = ComposerActions(onAlsoToChannel = { draft.value = draft.value.copy(alsoToChannel = it) }))
            }
        }
        compose.onNode(hasContentDescription("Add a reply") and hasSetTextAction()).performClick()

        // Slack names the channel as its header does: a private one by its lock.
        val box = compose.onNode(isToggleable())
        box.assert(hasText("Also send to") and hasText("ops") and hasContentDescription("Private channel")).assertIsOff()
        box.performClick()
        compose.runOnIdle { assertTrue(draft.value.alsoToChannel) }
        box.assertIsOn()

        room.value = channel.copy(name = "Mira", direct = true, isPrivate = false)
        compose.onNode(isToggleable()).assert(hasText("Also send as direct message"))
    }
}
