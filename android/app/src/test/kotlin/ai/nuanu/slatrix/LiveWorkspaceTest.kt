package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performTextInput
import androidx.compose.runtime.mutableStateOf
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
class LiveWorkspaceTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun anUnreadRoomOpensFromTheLiveHome() {
        val rooms = RoomListState(listOf(RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.Count("3"), "T", 0)), loading = false)
        var opened: String? = null
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", rooms, { opened = it }, {}, {}) } }
        compose.onNodeWithText("3").assertExists()
        compose.onNodeWithText("Team").performClick()
        compose.runOnIdle { assertEquals("!team:example.org", opened) }
    }

    @Test fun theComposerStaysEditableWhileThePreviousMessageIsSending() {
        val room = RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)
        val draft = mutableStateOf(ComposerState(text = "First message", loading = false))
        var submitted: String? = null
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(loading = false), draft.value,
                    { draft.value = draft.value.copy(text = it) },
                    { submitted = draft.value.text; draft.value = draft.value.copy(sending = true) }, {}, {}, {})
            }
        }
        compose.onNodeWithContentDescription("Send message").performClick()
        compose.runOnIdle { assertEquals("First message", submitted) }
        compose.onNodeWithContentDescription("Message #Team").performTextInput(" and another thought")
        compose.runOnIdle { assertEquals("First message and another thought", draft.value.text) }
    }
}
