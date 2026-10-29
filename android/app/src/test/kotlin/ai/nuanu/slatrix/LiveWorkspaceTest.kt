package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SpaceSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.runtime.CompositionLocalProvider
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

    // capability: home.workspace-switcher
    @Test fun choosingATestWorkspaceHidesOtherWorkspacesChannels() {
        val nuanu = RoomSummary("!work:example.org", "Work channel", false, "", UnreadBadge.None, "W", 0, setOf("!nuanu:example.org"))
        val test = RoomSummary("!test:example.org", "Test channel", false, "", UnreadBadge.None, "T", 1, setOf("!studio:example.org"))
        val direct = RoomSummary("!sam:example.org", "Sam", true, "", UnreadBadge.None, "S", 2)
        val rooms = RoomListState(listOf(nuanu, test, direct), loading = false, spacesKnown = true, spaces = listOf(
            SpaceSummary("!nuanu:example.org", "Nuanu", true, "N", 0),
            SpaceSummary("!studio:example.org", "Test Studio", true, "TS", 1),
        ))
        val selected = mutableStateOf<String?>(null)
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", rooms, {}, {}, {}, selected.value, { selected.value = it }) } }
        compose.onNodeWithContentDescription("Switch workspace").performClick()
        compose.onNodeWithText("Test Studio").performClick()
        compose.onNodeWithText("Test channel").assertExists()
        compose.onNodeWithText("Sam").assertExists()
        compose.onNodeWithText("Work channel").assertDoesNotExist()
    }

    // capability: composer.send
    @Test fun theComposerStaysEditableWhileThePreviousMessageIsSending() {
        val room = RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)
        val draft = mutableStateOf(ComposerState(text = "First message", loading = false))
        var submitted: String? = null
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(loading = false), draft.value,
                    { draft.value = draft.value.copy(text = it) },
                    { submitted = draft.value.text; draft.value = draft.value.copy(sending = true) }, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNodeWithContentDescription("Send message").performClick()
        compose.runOnIdle { assertEquals("First message", submitted) }
        compose.onNodeWithContentDescription("Message #Team").performTextReplacement("Another thought")
        compose.runOnIdle { assertEquals("Another thought", draft.value.text) }
    }

    // capability: conversation.read
    @Test fun onlyTheLatestVisibleMessageIsReadWhileTheActivityIsResumed() {
        val room = RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)
        fun message(id: String) = ConversationMessage(id, "\$$id", "@sam:example.org", "Sam", id, null,
            0, MessageKind.Text, MessageSendState.Sent, false, "S", 0)
        val timeline = mutableStateOf(ConversationState(listOf(message("First")), loading = false, hasMore = false))
        val owner = object : LifecycleOwner { override val lifecycle = LifecycleRegistry(this) }
        compose.runOnUiThread { owner.lifecycle.currentState = Lifecycle.State.RESUMED }
        var read: String? = null
        compose.setContent {
            SlatrixTheme { CompositionLocalProvider(LocalLifecycleOwner provides owner) {
                LiveChannelScreen(room, timeline.value, ComposerState(loading = false), {}, {}, {}, {}, { read = it }, {}, {}, {})
            } }
        }
        compose.onNodeWithText("First").assertExists()
        compose.waitUntil { read == "\$First" }
        compose.runOnIdle {
            owner.lifecycle.currentState = Lifecycle.State.STARTED
            timeline.value = timeline.value.copy(rows = timeline.value.rows + message("Next"))
        }
        compose.onNodeWithText("Next").assertIsDisplayed()
        compose.runOnIdle { assertEquals("\$First", read) }
        compose.runOnIdle { owner.lifecycle.currentState = Lifecycle.State.RESUMED }
        compose.waitForIdle()
        compose.waitUntil { read == "\$Next" }
    }
}
