package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ActivityItem
import ai.nuanu.slatrix.core.ActivityKind
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.MessageThread
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.ThreadFeedItem
import ai.nuanu.slatrix.core.ThreadFeedMessage
import ai.nuanu.slatrix.core.ThreadFeedState
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ActivityScreen
import ai.nuanu.slatrix.ui.account.AvatarLoader
import ai.nuanu.slatrix.ui.account.ChannelDetailsActions
import ai.nuanu.slatrix.ui.account.ChannelDetailsScreen
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.account.LocalAvatarLoader
import ai.nuanu.slatrix.ui.account.PinnedMessages
import ai.nuanu.slatrix.ui.account.ThreadsFeed
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import java.util.Collections
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Each place that names a sender asks for that sender's picture. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class SenderPicturesTest {
    @get:Rule val compose = createComposeRule()

    private val asked: MutableSet<String> = Collections.synchronizedSet(mutableSetOf())

    private fun show(content: @Composable () -> Unit) {
        compose.setContent {
            CompositionLocalProvider(LocalAvatarLoader provides object : AvatarLoader {
                override suspend fun load(url: String, sizePx: Int): ImageBitmap? = null.also { asked += url }
            }) { SlatrixTheme(content = content) }
        }
    }

    private fun assertAsked(url: String) = compose.runOnIdle { assertTrue("Asked for $url", url in asked) }

    // capability: people.avatars
    @Test fun anActivityItemShowsItsSendersPicture() {
        show {
            ActivityScreen(listOf(ActivityItem("1", "!team:example.org", "\$1", "design", false, "Sam", "S", 0, "Can you review?", 0,
                ActivityKind.Mention, null, avatarUrl = "mxc://example.org/sam")), {}, { _, _ -> })
        }
        assertAsked("mxc://example.org/sam")
    }

    // capability: people.avatars
    @Test fun aThreadInTheFeedShowsItsAuthorsPicture() {
        val thread = ThreadFeedItem("!design:example.org", "design", false, "\$root",
            ThreadFeedMessage("Sam", "S", 0, "Shall we ship?", 1_000, "mxc://example.org/sam"),
            ThreadFeedMessage("Mira", "M", 1, "Yes, Friday", 2_000, "mxc://example.org/mira"), replies = 3, unread = true)
        show { ActivityScreen(emptyList(), {}, { _, _ -> }) { ThreadsFeed(ThreadFeedState(listOf(thread), loading = false), it) } }
        compose.onNodeWithText("Threads").performClick()
        assertAsked("mxc://example.org/sam")
    }

    // capability: people.avatars
    @Test fun aPinnedMessageShowsItsSendersPicture() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0, pinned = listOf("\$pin"))
        val pin = message("Ship it").copy(eventId = "\$pin", avatarUrl = "mxc://example.org/mira")
        show {
            ChannelDetailsScreen(room, null, ChannelDetailsActions(pins = {
                PinnedMessages(ConversationState(listOf(pin), loading = false)) {}
            }), {}, {}, emptyList()) {}
        }
        compose.onNodeWithText("Pinned messages").performClick()
        assertAsked("mxc://example.org/mira")
    }

    // capability: people.avatars
    @Test fun aThreadSummaryShowsItsLastRepliersPicture() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        val root = message("Plan?").copy(thread = MessageThread(3, "Sam Okafor", 1_700_000_600_000L, "mxc://example.org/sam"))
        show {
            LiveChannelScreen(room, ConversationState(listOf(root), loading = false, hasMore = false), ComposerState(loading = false),
                {}, {}, {}, {}, {}, {}, {}, {})
        }
        assertAsked("mxc://example.org/sam")
    }

    private fun message(body: String) = ConversationMessage(body, "\$$body", "@mira:example.org", "Mira", body, null,
        1_700_000_000_000L, MessageKind.Text, MessageSendState.Sent, false, "M", 0)
}
