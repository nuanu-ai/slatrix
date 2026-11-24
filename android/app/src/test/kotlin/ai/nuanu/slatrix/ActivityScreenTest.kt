package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ActivityItem
import ai.nuanu.slatrix.core.ActivityKind
import ai.nuanu.slatrix.core.Invitation
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ActivityScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertEquals
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
        compose.setContent { SlatrixTheme { ActivityScreen(items, {}, {}) } }
        listOf("Can you review?", "Agreed", "Lunch?").forEach { compose.onNodeWithText(it).assertExists() }
        compose.onNodeWithText("Mentioned in #design").assertExists()

        compose.onNodeWithText("Mentions").performClick()
        compose.onNodeWithText("Can you review?").assertExists()
        compose.onNodeWithText("Agreed").assertDoesNotExist()
        compose.onNodeWithText("DMs").performClick()
        compose.onNodeWithText("Lunch?").assertExists()
        compose.onNodeWithText("Can you review?").assertDoesNotExist()
    }

    // capability: activity.feed
    @Test fun aReactionNamesItsEmojiAboveTheMessageItReactedTo() {
        val liked = item("\$r", ActivityKind.Reaction, "👍").copy(reactedTo = "Ship it on Friday?")
        compose.setContent { SlatrixTheme { ActivityScreen(listOf(liked), {}, {}) } }
        compose.onNodeWithText("Reacted 👍 in #design").assertExists()
        compose.onNodeWithText("Ship it on Friday?").assertExists()
    }

    // capability: activity.feed
    @Test fun theUnreadsPillShowsOnlyWhatYouHaventOpenedYet() {
        val items = listOf(item("\$m", ActivityKind.Mention, "Can you review?"), item("\$d", ActivityKind.Message, "Lunch?", direct = true).copy(unread = false))
        compose.setContent { SlatrixTheme { ActivityScreen(items, {}, {}) } }
        compose.onNodeWithText("Can you review?").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Unread"))
        compose.onNodeWithText("Lunch?").assert(SemanticsMatcher.keyNotDefined(SemanticsProperties.StateDescription))
        compose.onNodeWithText("Unreads").performClick()
        compose.onNodeWithText("Can you review?").assertExists()
        compose.onNodeWithText("Lunch?").assertDoesNotExist()
        compose.onNodeWithText("Unreads").performClick()
        compose.onNodeWithText("Lunch?").assertExists()
    }

    // capability: activity.feed
    @Test fun anEmptyFeedSaysSoInTheMiddleWithUnreadsAmongTheFilters() {
        compose.setContent { SlatrixTheme { ActivityScreen(emptyList(), {}, {}) } }
        fun bounds(text: String) = compose.onNodeWithText(text, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        val root = compose.onRoot().fetchSemanticsNode().boundsInRoot
        assertEquals(root.center.x, bounds("You’re all caught up").center.x, 1f)
        assertEquals(bounds("All").center.y, bounds("Unreads").center.y, 1f)
    }

    // capability: activity.open-item
    @Test fun anItemOpensAtItsOwnMessageAndAThreadReplyNamesItsThread() {
        val items = listOf(item("\$m", ActivityKind.Mention, "Can you review?"), item("\$t", ActivityKind.ThreadReply, "Agreed", thread = "\$root"))
        var opened: ActivityItem? = null
        compose.setContent { SlatrixTheme { ActivityScreen(items, { opened = it }, {}) } }
        compose.onNodeWithText("Agreed").performClick()
        compose.runOnIdle { assertEquals("\$t" to "\$root", opened?.eventId to opened?.threadRoot) }
        compose.onNodeWithText("Can you review?").performClick()
        compose.runOnIdle { assertEquals("\$m" to null, opened?.eventId to opened?.threadRoot) }
    }

    // capability: activity.feed
    @Test fun invitationsAndUnreadMentionRoomsShowAtTopAndFollowFilters() {
        val channelInvite = Invitation("!inv-ch:example.org", "launch", inviter = "Mira")
        val dmInvite = Invitation("!inv-dm:example.org", "Alex", direct = true)
        val channelMention = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.Count("2"), "D", 0, mentions = 2)
        val dmMention = RoomSummary("!dm:example.org", "Jordan", true, "", UnreadBadge.Count("1"), "J", 1, mentions = 1)
        val reply = item("\$t", ActivityKind.ThreadReply, "Agreed", thread = "\$root").copy(unread = false)
        var openedInvite: String? = null
        var openedRoom: RoomSummary? = null
        compose.setContent {
            SlatrixTheme {
                ActivityScreen(
                    items = listOf(reply), onOpenItem = {}, onOpenThread = {},
                    invitations = listOf(channelInvite, dmInvite),
                    mentionRooms = listOf(channelMention, dmMention),
                    onOpenInvitation = { openedInvite = it },
                    onOpenRoom = { openedRoom = it },
                )
            }
        }
        compose.onNodeWithText("#launch").assertExists()
        compose.onNodeWithText("Mira invited you").assertExists()
        compose.onNodeWithText("Alex").assertExists()
        compose.onNodeWithText("#design").assertExists()
        compose.onNodeWithText("2 unread mentions").assertExists()
        compose.onNodeWithText("Jordan").assertExists()
        compose.onNodeWithText("1 unread mention").assertExists()
        compose.onNodeWithText("You’re all caught up").assertDoesNotExist()
        assertTrue(compose.onNodeWithText("#launch").fetchSemanticsNode().boundsInRoot.top <
            compose.onNodeWithText("Agreed").fetchSemanticsNode().boundsInRoot.top)
        assertTrue(compose.onNodeWithText("#design").fetchSemanticsNode().boundsInRoot.top <
            compose.onNodeWithText("Agreed").fetchSemanticsNode().boundsInRoot.top)

        compose.onNodeWithText("#launch").performClick()
        compose.onNodeWithText("#design").performClick()
        compose.runOnIdle {
            assertEquals("!inv-ch:example.org", openedInvite)
            assertEquals(channelMention, openedRoom)
        }

        // Mentions shows mention rooms, not invitations or non-mention items.
        compose.onNodeWithText("Mentions").performClick()
        compose.onNodeWithText("#design").assertExists()
        compose.onNodeWithText("Jordan").assertExists()
        compose.onNodeWithText("#launch").assertDoesNotExist()
        compose.onNodeWithText("Agreed").assertDoesNotExist()

        // Unreads keeps mention rooms visible under Mentions and invitations visible under All.
        compose.onNodeWithText("Unreads").performClick()
        compose.onNodeWithText("#design").assertExists()
        compose.onNodeWithText("All").performClick()
        compose.onNodeWithText("#launch").assertExists()
        compose.onNodeWithText("#design").assertExists()
        compose.onNodeWithText("Agreed").assertDoesNotExist()

        // DMs shows direct invitations and direct mention rooms only.
        compose.onNodeWithText("DMs").performClick()
        compose.onNodeWithText("Alex").assertExists()
        compose.onNodeWithText("Jordan").assertExists()
        compose.onNodeWithText("#launch").assertDoesNotExist()
        compose.onNodeWithText("#design").assertDoesNotExist()
    }

    // capability: activity.feed
    @Test fun aMentionRoomShowsWhenItsUnreadMentionsAreNotAlreadyListedInTheFeed() {
        val room = RoomSummary("!team:example.org", "design", false, "", UnreadBadge.Count("1"), "D", 0, mentions = 1)
        val liveMention = item("\$m", ActivityKind.Mention, "@Alex can you review?")
        compose.setContent {
            SlatrixTheme {
                ActivityScreen(
                    items = listOf(liveMention), onOpenItem = {}, onOpenThread = {},
                    mentionRooms = listOf(room),
                )
            }
        }
        compose.onNodeWithText("@Alex can you review?").assertExists()
        compose.onNodeWithText("1 unread mention").assertDoesNotExist()
    }

    // capability: activity.feed
    @Test fun aMentionRoomStillShowsWhenTheListedMentionWasMarkedReadOrMoreMentionsExist() {
        val room = RoomSummary("!team:example.org", "design", false, "", UnreadBadge.Count("1"), "D", 0, mentions = 1)
        val readMention = item("\$m", ActivityKind.Mention, "@Alex can you review?").copy(unread = false)
        compose.setContent {
            SlatrixTheme {
                ActivityScreen(
                    items = listOf(readMention), onOpenItem = {}, onOpenThread = {},
                    mentionRooms = listOf(room),
                )
            }
        }
        compose.onNodeWithText("1 unread mention").assertExists()
    }
}
