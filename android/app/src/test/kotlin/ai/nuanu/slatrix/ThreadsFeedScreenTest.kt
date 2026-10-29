package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ThreadFeedItem
import ai.nuanu.slatrix.core.ThreadFeedMessage
import ai.nuanu.slatrix.core.ThreadFeedState
import ai.nuanu.slatrix.ui.account.ActivityScreen
import ai.nuanu.slatrix.ui.account.ThreadsFeed
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
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
class ThreadsFeedScreenTest {
    @get:Rule val compose = createComposeRule()

    // capability: threads.feed
    @Test fun activitysThreadsFilterListsYourThreadsAndOpensOne() {
        val thread = ThreadFeedItem("!design:example.org", "design", false, "\$root",
            ThreadFeedMessage("Sam", "S", 0, "Shall we ship?", 1_000), ThreadFeedMessage("Mira", "M", 1, "Yes, Friday", 2_000),
            replies = 3, unread = true)
        var opened: Pair<String, String>? = null
        compose.setContent {
            SlatrixTheme {
                ActivityScreen(emptyList(), {}, { room, root -> opened = room to root }) { onOpenThread ->
                    ThreadsFeed(ThreadFeedState(listOf(thread), loading = false), onOpenThread)
                }
            }
        }
        compose.onNodeWithText("Shall we ship?").assertDoesNotExist()
        compose.onNodeWithText("Threads").performClick()
        compose.onNodeWithText("#design").assertExists()
        compose.onNodeWithText("Yes, Friday", substring = true).assertExists()
        compose.onNodeWithText("3 replies").assertExists()
        compose.onNodeWithText("Shall we ship?").performClick()
        compose.runOnIdle { assertEquals("!design:example.org" to "\$root", opened) }
    }
}
