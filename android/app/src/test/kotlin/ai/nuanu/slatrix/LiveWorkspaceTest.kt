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
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasContentDescription
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
import ai.nuanu.slatrix.ui.account.LiveWorkspace
import ai.nuanu.slatrix.ui.account.WorkspaceCover
import androidx.activity.compose.BackHandler
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import org.junit.Assert.assertFalse
import androidx.compose.runtime.produceState
import androidx.compose.runtime.snapshots.Snapshot
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
        compose.onNode(hasContentDescription("Message #Team") and hasSetTextAction()).performClick()
        compose.onNodeWithContentDescription("Send message").performClick()
        compose.runOnIdle { assertEquals("First message", submitted) }
        compose.onNodeWithContentDescription("Message #Team").performTextReplacement("Another thought")
        compose.runOnIdle { assertEquals("Another thought", draft.value.text) }
    }

    // Back to a profile redrew it from nothing: its photo from an empty circle, its name small and then full size.
    @Test fun aPageUnderAnotherIsAsItWasWhenItShowsAgain() {
        val editing = mutableStateOf(false)
        compose.setContent {
            SlatrixTheme {
                LiveWorkspace(listOfNotNull(
                    WorkspaceCover("profile") {
                        val name by produceState("…") { value = "Mira Chen" }
                        Text("Profile of $name")
                    },
                    WorkspaceCover("edit") { Text("Edit profile") }.takeIf { editing.value },
                )) { Text("Home") }
            }
        }
        compose.onNodeWithText("Profile of Mira Chen").assertIsDisplayed()
        compose.runOnIdle { editing.value = true }
        compose.onNodeWithText("Edit profile").assertIsDisplayed()
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { editing.value = false; Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Profile of Mira Chen").assertIsDisplayed()
    }

    @Test fun aConversationUnderAnotherPageReadsNothingAndTakesNoBack() {
        val room = RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)
        fun message(id: String) = ConversationMessage(id, "\$$id", "@sam:example.org", "Sam", id, null,
            0, MessageKind.Text, MessageSendState.Sent, false, "S", 0)
        val timeline = mutableStateOf(ConversationState(listOf(message("First")), loading = false, hasMore = false))
        val profile = mutableStateOf(false)
        var read: String? = null
        var left = false
        compose.setContent {
            SlatrixTheme {
                LiveWorkspace(listOfNotNull(
                    WorkspaceCover("team") {
                        LiveChannelScreen(room, timeline.value, ComposerState(loading = false), {}, {}, { left = true }, {}, { read = it }, {}, {}, {})
                    },
                    WorkspaceCover("profile") { BackHandler { profile.value = false }; Text("Profile") }.takeIf { profile.value },
                )) { Text("Home") }
            }
        }
        compose.waitUntil { read == "\$First" }
        compose.runOnIdle { profile.value = true }
        compose.onNodeWithText("Profile").assertIsDisplayed()
        compose.runOnIdle { timeline.value = timeline.value.copy(rows = timeline.value.rows + message("Next")) }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals("\$First", read) }
        compose.runOnIdle { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithText("Next").assertIsDisplayed()
        compose.runOnIdle { assertFalse("Back closed the page on top, not the conversation under it", left) }
        compose.waitUntil { read == "\$Next" }
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
