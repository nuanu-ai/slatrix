package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ChannelActionFailure
import ai.nuanu.slatrix.core.ChannelMember
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.NotificationChoice
import ai.nuanu.slatrix.core.NotificationSetting
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ChannelDetailsActions
import ai.nuanu.slatrix.ui.account.ChannelDetailsScreen
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.account.PinnedMessages
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
class ChannelDetailsScreenTest {
    @get:Rule val compose = createComposeRule()
    private val room = RoomSummary("!design:example.org", "design", false, "Launch reviews", UnreadBadge.None, "D", 0,
        memberCount = 3, canEditName = true, canEditTopic = true)

    // capability: channel.details
    @Test fun theHeaderPillOpensTheDetails() {
        var opened = false
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(loading = false, hasMore = false), ComposerState(loading = false),
                    {}, {}, {}, {}, {}, {}, {}, {}, onOpenDetails = { opened = true })
            }
        }
        compose.onNodeWithText("Launch reviews").performClick()
        compose.runOnIdle { assertTrue(opened) }
    }

    // capability: channel.details
    @Test fun editingSavesOnlyTheNameOrDescriptionThatChanged() {
        val saved = mutableListOf<Pair<String?, String?>>()
        details(room, ChannelDetailsActions(save = { name, topic -> saved += name to topic }))
        compose.onNodeWithText("Launch reviews").assertIsDisplayed()
        compose.onNodeWithText("Edit").performClick()
        compose.onNodeWithText("Description").performTextReplacement("Critique")
        compose.onNodeWithText("Save").performClick()
        compose.onNodeWithText("Channel details").assertIsDisplayed()

        compose.onNodeWithText("Edit").performClick()
        compose.onNodeWithText("Name").performTextReplacement("studio ")
        compose.onNodeWithText("Save").performClick()
        compose.onNodeWithText("Channel details").assertIsDisplayed()
        compose.runOnIdle { assertEquals(listOf<Pair<String?, String?>>(null to "Critique", "studio" to null), saved) }
    }

    @Test fun withoutThePowerToChangeEitherThereIsNoEdit() {
        details(room.copy(canEditName = false, canEditTopic = false))
        compose.onNodeWithText("Channel details").assertIsDisplayed()
        compose.onNodeWithText("Edit").assertDoesNotExist()
    }

    // capability: conversation.members
    @Test fun membersListsWhoIsInTheChannelAndFindsThemByName() {
        details(room, ChannelDetailsActions(members = {
            listOf(ChannelMember("@avery:example.org", "Avery"), ChannelMember("@mira:example.org", "Mira"),
                ChannelMember("@sam:example.org", "Sam"))
        }), me = "@sam:example.org")
        compose.onNodeWithText("3").assertIsDisplayed()
        compose.onNodeWithText("Members").performClick()
        compose.onNodeWithText("Avery").assertIsDisplayed()
        compose.onNodeWithText("(you)").assertIsDisplayed()
        compose.onNodeWithContentDescription("Search members").performTextInput("mi")
        compose.onNodeWithText("Mira").assertIsDisplayed()
        compose.onNodeWithText("Avery").assertDoesNotExist()
    }

    // capability: channel.leave
    @Test fun leavingAsksFirstAndThenLeaves() {
        var left = false
        var gone = false
        details(room, ChannelDetailsActions(leave = { left = true }), onLeft = { gone = true })
        compose.onNodeWithText("Leave channel").performClick()
        compose.onNodeWithText("You may need an invitation to rejoin.").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { assertFalse(left) }

        compose.onNodeWithText("Leave channel").performClick()
        compose.onNodeWithText("Leave").performClick()
        compose.waitUntil { gone }
        compose.runOnIdle { assertTrue(left) }
    }

    @Test fun aLeaveThatFailsSaysWhyAndStays() {
        var gone = false
        details(room, ChannelDetailsActions(leave = { throw ChannelActionFailure("You’re no longer in this conversation.") }),
            onLeft = { gone = true })
        compose.onNodeWithText("Leave channel").performClick()
        compose.onNodeWithText("Leave").performClick()
        compose.onNodeWithText("You’re no longer in this conversation.").assertIsDisplayed()
        compose.runOnIdle { assertFalse(gone) }
    }

    // capability: conversation.notifications
    @Test fun notificationsShowTheChoiceAndSaveANewOne() {
        val chosen = mutableListOf<NotificationChoice>()
        details(room, ChannelDetailsActions(
            notifications = { NotificationSetting(NotificationChoice.Default, NotificationChoice.Mentions) },
            setNotifications = { chosen += it }))
        compose.onNodeWithText("Default (Mentions and keywords)").assertIsDisplayed()
        compose.onNodeWithText("Notifications").performClick()
        compose.onNodeWithText("Nothing").performClick()
        compose.onNodeWithText("Nothing").assertIsSelected()
        compose.runOnIdle { assertEquals(listOf(NotificationChoice.Nothing), chosen) }
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Nothing").assertIsDisplayed()
    }

    @Test fun aNotificationChoiceThatFailsGoesBack() {
        details(room, ChannelDetailsActions(
            notifications = { NotificationSetting(NotificationChoice.All, NotificationChoice.Mentions) },
            setNotifications = { throw ChannelActionFailure("Something went wrong. Try again.") }))
        compose.onNodeWithText("Notifications").performClick()
        compose.onNodeWithText("Nothing").performClick()
        compose.onNodeWithText("Something went wrong. Try again.").assertIsDisplayed()
        compose.onNodeWithText("All new messages").assertIsSelected()
    }

    @Test fun notificationsThatCouldNotLoadSayWhyAndTryAgain() {
        var loads = 0
        details(room, ChannelDetailsActions(notifications = {
            if (loads++ == 0) throw ChannelActionFailure("This conversation is still loading. Try again.")
            NotificationSetting(NotificationChoice.Mentions, NotificationChoice.All)
        }))
        compose.onNodeWithText("Notifications").performClick()
        compose.onNodeWithText("This conversation is still loading. Try again.").assertIsDisplayed()
        compose.onNodeWithText("Try again").performClick()
        compose.onNodeWithText("Mentions and keywords").assertIsSelected()
    }

    @Test fun addPeopleOpenedFromMembersGoesBackToMembers() {
        details(room)
        compose.onNodeWithText("Members").performClick()
        compose.onNodeWithText("Add people").performClick()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithContentDescription("Search members").assertIsDisplayed()
    }

    // capability: channel.invite
    @Test fun addingPeopleInvitesTheMatrixIdOrSaysWhyNot() {
        val invited = mutableListOf<String>()
        details(room, ChannelDetailsActions(invite = { id ->
            if (!id.startsWith("@")) throw ChannelActionFailure("Enter a complete Matrix ID, such as @name:example.org.")
            invited += id
        }))
        compose.onNodeWithText("Add people").performClick()
        compose.onNodeWithText("Matrix ID").performTextInput("sam")
        compose.onNodeWithText("Add").performClick()
        compose.onNodeWithText("Enter a complete Matrix ID, such as @name:example.org.").assertIsDisplayed()
        compose.onNodeWithText("Matrix ID").performTextReplacement("@sam:example.org")
        compose.onNodeWithText("Add").performClick()
        compose.onNodeWithText("Channel details").assertIsDisplayed()
        compose.runOnIdle { assertEquals(listOf("@sam:example.org"), invited) }
    }

    @Test fun withoutThePowerToInviteThereIsNoAddPeople() {
        details(room.copy(canInvite = false))
        compose.onNodeWithText("Channel details").assertIsDisplayed()
        compose.onNodeWithText("Add people").assertDoesNotExist()
    }

    // capability: conversation.pins
    @Test fun pinnedMessagesListTheNewestPinFirstOpenWhereTheyAreAndUnpin() {
        val unpinned = mutableListOf<String>()
        var opened: String? = null
        details(room.copy(pinned = listOf("\$Ship it", "\$Launch at noon"), canPin = true), ChannelDetailsActions(pins = {
            PinnedMessages(ConversationState(listOf(pinned("Ship it"), pinned("Launch at noon")), loading = false)) { unpinned += it.body }
        }), onOpenMessage = { opened = it })
        compose.onNodeWithText("2").assertIsDisplayed()
        compose.onNodeWithText("Pinned messages").performClick()
        val newest = compose.onNodeWithText("Launch at noon").fetchSemanticsNode().boundsInRoot
        val oldest = compose.onNodeWithText("Ship it").fetchSemanticsNode().boundsInRoot
        assertTrue("The newest pin comes first", newest.bottom <= oldest.top)

        compose.onAllNodesWithContentDescription("Unpin")[1].performClick()
        compose.onNodeWithText("Ship it").performClick()
        compose.runOnIdle {
            assertEquals(listOf("Ship it"), unpinned)
            assertEquals("\$Ship it", opened)
        }
    }

    @Test fun pinsThatDidNotLoadSaySoRatherThanNone() {
        details(room.copy(pinned = listOf("\$Ship it")), ChannelDetailsActions(pins = {
            PinnedMessages(ConversationState(loading = false)) {}
        }))
        compose.onNodeWithText("Pinned messages").performClick()
        compose.onNodeWithText("Couldn’t load pins").assertIsDisplayed()
        compose.onNodeWithText("No pinned messages").assertDoesNotExist()
    }

    @Test fun withoutThePowerToPinPinsCantBeUnpinned() {
        details(room.copy(pinned = listOf("\$Ship it")), ChannelDetailsActions(pins = {
            PinnedMessages(ConversationState(listOf(pinned("Ship it")), loading = false)) {}
        }))
        compose.onNodeWithText("Pinned messages").performClick()
        compose.onNodeWithText("Ship it").assertIsDisplayed()
        compose.onNodeWithContentDescription("Unpin").assertDoesNotExist()
    }

    private fun pinned(body: String) = ConversationMessage(body, "\$$body", "@mira:example.org", "Mira", body, null,
        1_700_000_000_000L, MessageKind.Text, MessageSendState.Sent, false, "M", 0)

    private fun details(room: RoomSummary, actions: ChannelDetailsActions = ChannelDetailsActions(), me: String? = null,
        onLeft: () -> Unit = {}, onOpenMessage: (String) -> Unit = {}) {
        compose.setContent { SlatrixTheme { ChannelDetailsScreen(room, me, actions, onLeft, onOpenMessage) {} } }
    }
}
