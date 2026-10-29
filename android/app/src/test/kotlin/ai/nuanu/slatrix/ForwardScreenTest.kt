package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ForwardScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class ForwardScreenTest {
    @get:Rule val compose = createComposeRule()

    // capability: message.forward
    @Test fun theMessageShowsAndAConversationFoundByNameReceivesIt() {
        val design = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        val rooms = listOf(design, RoomSummary("!general:example.org", "general", false, "", UnreadBadge.None, "G", 1),
            RoomSummary("!sam:example.org", "Sam Okafor", true, "", UnreadBadge.None, "SO", 2))
        val message = ConversationMessage("m", "\$m", "@mira:example.org", "Mira Chen", "Launch moves to Thursday", null,
            1_700_000_000_000L, MessageKind.Text, MessageSendState.Sent, false, "MC", 0)
        val forwarded = mutableListOf<String>()
        compose.setContent { SlatrixTheme { ForwardScreen(message, design, rooms, { null }, { forwarded += it.id }) {} } }

        compose.onNodeWithText("Launch moves to Thursday").assertExists()
        compose.onNodeWithText("Mira Chen").assertExists()
        compose.onNode(hasSetTextAction()).performTextInput("gen")
        compose.onNodeWithText("Sam Okafor").assertDoesNotExist()
        compose.onNodeWithText("general").performClick()
        compose.runOnIdle { assertEquals(listOf("!general:example.org"), forwarded) }
    }

    @Test fun aRefusalStaysOnThePageAndATapWhileSendingSendsNothingMore() {
        val design = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        val news = RoomSummary("!news:example.org", "news", false, "", UnreadBadge.None, "N", 1)
        val message = ConversationMessage("m", "\$m", "@mira:example.org", "Mira Chen", "Launch moves to Thursday", null,
            1_700_000_000_000L, MessageKind.Text, MessageSendState.Sent, false, "MC", 0)
        val answer = CompletableDeferred<String?>()
        var asked = 0
        var forwarded = 0
        compose.setContent {
            SlatrixTheme { ForwardScreen(message, design, listOf(design, news), { asked++; answer.await() }, { forwarded++ }) {} }
        }
        compose.onNodeWithText("news").performClick()
        compose.onNodeWithText("news").performClick()
        answer.complete("You can’t post in that conversation. Choose another.")
        compose.onNodeWithText("You can’t post in that conversation. Choose another.").assertIsDisplayed()
        compose.runOnIdle {
            assertEquals(1, asked)
            assertEquals(0, forwarded)
        }
    }
}
