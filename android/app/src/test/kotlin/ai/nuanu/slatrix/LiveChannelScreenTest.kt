package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class LiveChannelScreenTest {
    @get:Rule val compose = createComposeRule()
    private val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)

    @Test fun olderHistoryLoadsAsTheReaderNearsTheTop() {
        val many = (1..200).map { message("Message $it", minutes = it) }
        val state = mutableStateOf(ConversationState(many, loading = false))
        var requests = 0
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, state.value, ComposerState(loading = false), {}, {}, {}, { requests++ }, {}, {})
            }
        }
        compose.onNodeWithText("Message 200").assertExists()
        compose.runOnIdle { assertEquals("The newest page is far from the top", 0, requests) }
        compose.onNodeWithText("Earlier messages").assertDoesNotExist()

        repeat(20) { compose.onRoot().performTouchInput { swipeDown() } }
        compose.waitUntil { requests == 1 }
        compose.runOnIdle { state.value = state.value.copy(loadingHistory = true) }
        compose.runOnIdle { state.value = state.value.copy(loadingHistory = false) }
        compose.waitUntil("A page that showed nothing asks again while the top is near") { requests == 2 }
    }

    private fun message(body: String, minutes: Int, sender: String = "Mira", state: MessageSendState = MessageSendState.Sent) =
        ConversationMessage(body, "\$$body", "@${sender.lowercase()}:example.org", sender, body, null,
            1_700_000_000_000L + minutes * 600_000L, MessageKind.Text, state, sender == "Jordan", sender.take(1), 0)
}
