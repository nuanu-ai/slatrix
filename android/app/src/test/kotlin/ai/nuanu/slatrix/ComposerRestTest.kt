package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ComposerActions
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
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
class ComposerRestTest {
    @get:Rule val compose = createComposeRule()
    private val text = mutableStateOf("")

    private fun show(room: RoomSummary = RoomSummary("!general:example.org", "general", false, "", UnreadBadge.None, "G", 0)) {
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(emptyList(), loading = false, hasMore = false),
                    ComposerState(text.value, loading = false), { text.value = it }, {}, {}, {}, {}, {}, {}, {},
                    composerActions = ComposerActions(onAttach = {}, onFormat = { _, _, _, _ -> }))
            }
        }
    }

    private val toolbar = listOf("Send message", "Emoji", "Mention someone", "Formatting")

    @Test fun atRestTheComposerIsOneRowOfPlusAndPlaceholderAndFocusingOpensTheToolbar() {
        show()
        compose.onNodeWithContentDescription("Attachments").assertExists()
        toolbar.forEach { compose.onNodeWithContentDescription(it).assertDoesNotExist() }

        compose.onNodeWithContentDescription("Message #general").performClick()
        compose.onNodeWithContentDescription("Message #general").assertIsFocused()
        toolbar.forEach { compose.onNodeWithContentDescription(it).assertExists() }
        compose.onNodeWithContentDescription("Message #general").performTextInput("Morning")
        compose.runOnIdle { assertEquals("Morning", text.value) }
        compose.onNodeWithContentDescription("Message #general").assertIsFocused()
    }

    @Test fun aDraftArrivingWhileYouReadKeepsTheComposerOneRow() {
        show()
        val resting = compose.onNodeWithContentDescription("Message #general").fetchSemanticsNode().boundsInRoot
        compose.runOnIdle { text.value = "Half a thought" }
        compose.onNodeWithText("Half a thought", useUnmergedTree = true).assertExists()
        toolbar.forEach { compose.onNodeWithContentDescription(it).assertDoesNotExist() }
        assertEquals(resting, compose.onNodeWithContentDescription("Message #general").fetchSemanticsNode().boundsInRoot)
    }

    @Test fun aPrivateChannelsPlaceholderHasNoHash() {
        show(RoomSummary("!plans:example.org", "launch-plans", false, "", UnreadBadge.None, "L", 0, isPrivate = true))
        compose.onNodeWithContentDescription("Message launch-plans").assertExists()
    }
}
