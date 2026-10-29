package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ChannelActionFailure
import ai.nuanu.slatrix.core.ChannelMember
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.NotificationChoice
import ai.nuanu.slatrix.core.NotificationSetting
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ChannelDetailsActions
import ai.nuanu.slatrix.ui.account.ChannelDetailsScreen
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
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
    @Test fun editingSavesTheNameAndDescriptionWhereYourPowerLevelAllowsIt() {
        var saved: Pair<String, String>? = null
        details(room, ChannelDetailsActions(save = { name, topic -> saved = name to topic }))
        compose.onNodeWithText("Launch reviews").assertIsDisplayed()
        compose.onNodeWithText("Edit").performClick()
        compose.onNodeWithText("Name").performTextReplacement("studio")
        compose.onNodeWithText("Description").performTextReplacement("Critique")
        compose.onNodeWithText("Save").performClick()
        compose.onNodeWithText("Channel details").assertIsDisplayed()
        compose.runOnIdle { assertEquals("studio" to "Critique", saved) }
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
        var left = 0
        var gone = false
        details(room, ChannelDetailsActions(leave = { left++ }), onLeft = { gone = true })
        compose.onNodeWithText("Leave channel").performClick()
        compose.onNodeWithText("You may need an invitation to rejoin.").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { assertEquals(0, left) }

        compose.onNodeWithText("Leave channel").performClick()
        compose.onNodeWithText("Leave").performClick()
        compose.waitUntil { gone }
        compose.runOnIdle { assertEquals(1, left) }
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

    private fun details(room: RoomSummary, actions: ChannelDetailsActions = ChannelDetailsActions(), me: String? = null,
        onLeft: () -> Unit = {}) {
        compose.setContent { SlatrixTheme { ChannelDetailsScreen(room, me, actions, onLeft) {} } }
    }
}
