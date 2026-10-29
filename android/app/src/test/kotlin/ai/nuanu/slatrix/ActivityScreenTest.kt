package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ActivityItem
import ai.nuanu.slatrix.core.ActivityKind
import ai.nuanu.slatrix.ui.account.ActivityScreen
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
class ActivityScreenTest {
    @get:Rule val compose = createComposeRule()

    private fun item(event: String, kind: ActivityKind, body: String, direct: Boolean = false, thread: String? = null) =
        ActivityItem("!team:example.org $event", if (direct) "!sam:example.org" else "!team:example.org", event,
            if (direct) "Sam" else "design", direct, "Sam", "S", 0, body, 0, kind, thread)

    // capability: activity.feed
    @Test fun filtersShowOnlyTheirKindOfActivity() {
        val items = listOf(
            item("\$m", ActivityKind.Mention, "Can you review?"),
            item("\$t", ActivityKind.ThreadReply, "Agreed", thread = "\$root"),
            item("\$d", ActivityKind.Message, "Lunch?", direct = true),
        )
        compose.setContent { SlatrixTheme { ActivityScreen(items, {}, { _, _ -> }) } }
        listOf("Can you review?", "Agreed", "Lunch?").forEach { compose.onNodeWithText(it).assertExists() }
        compose.onNodeWithText("Mentioned in #design").assertExists()

        compose.onNodeWithText("Mentions").performClick()
        compose.onNodeWithText("Can you review?").assertExists()
        compose.onNodeWithText("Agreed").assertDoesNotExist()
        compose.onNodeWithText("DMs").performClick()
        compose.onNodeWithText("Lunch?").assertExists()
        compose.onNodeWithText("Can you review?").assertDoesNotExist()
    }

    // capability: activity.open-item
    @Test fun aThreadReplyOpensItsThreadAndAnyOtherItemItsConversation() {
        val items = listOf(item("\$m", ActivityKind.Mention, "Can you review?"), item("\$t", ActivityKind.ThreadReply, "Agreed", thread = "\$root"))
        var room: String? = null
        var thread: Pair<String, String>? = null
        compose.setContent { SlatrixTheme { ActivityScreen(items, { room = it }, { id, root -> thread = id to root }) } }
        compose.onNodeWithText("Agreed").performClick()
        compose.runOnIdle { assertEquals("!team:example.org" to "\$root", thread) }
        compose.onNodeWithText("Can you review?").performClick()
        compose.runOnIdle { assertEquals("!team:example.org", room) }
    }
}
