package ai.nuanu.slatrix

import ai.nuanu.slatrix.ui.mockups.SlatrixMockups
import android.app.Application
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
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
class SlackConversationTest {
    @get:Rule val compose = createComposeRule()

    @Test fun reactionsAndThreadRepliesShareOneCompactRow() {
        compose.setContent { SlatrixMockups() }
        compose.onNodeWithText("design").performClick()
        val replyLink = compose.onNodeWithText("3 replies").performScrollTo()
        val reaction = compose.onNodeWithText("4").fetchSemanticsNode().boundsInRoot
        val replies = replyLink.fetchSemanticsNode().boundsInRoot

        assertTrue(
            "A message's reaction and reply link should occupy the same row",
            reaction.top < replies.bottom && replies.top < reaction.bottom,
        )
    }
}
