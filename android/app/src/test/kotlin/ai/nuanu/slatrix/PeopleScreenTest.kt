package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ChannelMember
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.Person
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ChannelDetailsActions
import ai.nuanu.slatrix.ui.account.ChannelDetailsScreen
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.account.PersonProfileScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasProgressBarRangeInfo
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performFirstLinkClick
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Opening someone's profile from a conversation, and what the profile offers. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class PeopleScreenTest {
    @get:Rule val compose = createComposeRule()
    private val channel = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
    private val opened = mutableListOf<String>()

    private fun show(room: RoomSummary, vararg messages: ConversationMessage) {
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(messages.toList(), loading = false, hasMore = false, ownUserId = "@me:example.org"),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {}, onPerson = { opened += it })
            }
        }
    }

    // capability: people.profile
    @Test fun aSendersNameOrPictureOpensTheirProfile() {
        show(channel, message("Ship it"))
        compose.onNodeWithText("Mira").performClick()
        compose.onNodeWithContentDescription("Mira’s profile").performClick()
        compose.runOnIdle { assertEquals(listOf("@mira:example.org", "@mira:example.org"), opened) }
    }

    // capability: people.profile
    @Test fun aMentionOpensTheProfileOfWhoItNames() {
        show(channel, message("@sam look", html = "<a href=\"https://matrix.to/#/@sam:example.org\">Sam</a> look"))
        compose.onNodeWithText("@Sam look", useUnmergedTree = true).performFirstLinkClick()
        compose.runOnIdle { assertEquals(listOf("@sam:example.org"), opened) }
    }

    // capability: people.profile
    @Test fun aMemberOfTheConversationOpensTheirProfile() {
        compose.setContent {
            SlatrixTheme {
                ChannelDetailsScreen(channel, "@me:example.org", ChannelDetailsActions(members = { listOf(ChannelMember("@mira:example.org", "Mira Chen")) }),
                    onLeft = {}, onOpenMessage = {}, onPerson = { opened += it }) {}
            }
        }
        compose.onNodeWithText("Members").performClick()
        compose.onNodeWithText("Mira Chen").performClick()
        compose.runOnIdle { assertEquals(listOf("@mira:example.org"), opened) }
    }

    // capability: people.profile
    @Test fun aProfileShowsTheNameAndMatrixIdAndMessageOpensTheirDirectMessage() {
        var messaged = 0
        var back = 0
        compose.setContent {
            SlatrixTheme {
                PersonProfileScreen(Person("@mira:example.org", "Mira Chen"), own = false, opening = false, error = null,
                    onMessage = { messaged++ }, onBack = { back++ })
            }
        }
        compose.onNodeWithText("Mira Chen").assertIsDisplayed()
        compose.onNodeWithText("@mira:example.org").assertIsDisplayed()
        compose.onNodeWithText("Message").performClick()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.runOnIdle { assertEquals(1 to 1, messaged to back) }
    }

    @Test fun messageShowsProgressOnlyAfterAMomentWhileItOpens() {
        compose.mainClock.autoAdvance = false
        compose.setContent {
            SlatrixTheme {
                PersonProfileScreen(Person("@mira:example.org", "Mira Chen"), own = false, opening = true, error = null, onMessage = {}, onBack = {})
            }
        }
        val spinner = hasProgressBarRangeInfo(ProgressBarRangeInfo.Indeterminate)
        compose.mainClock.advanceTimeBy(100)
        compose.onNode(spinner).assertDoesNotExist()
        compose.mainClock.advanceTimeBy(500)
        compose.onNode(spinner).assertExists()
    }

    @Test fun yourOwnProfileOffersNoMessage() {
        compose.setContent {
            SlatrixTheme {
                PersonProfileScreen(Person("@me:example.org", "Alex Doe"), own = true, opening = false, error = null, onMessage = {}, onBack = {})
            }
        }
        compose.onNodeWithText("Alex Doe").assertIsDisplayed()
        compose.onNodeWithText("Message").assertDoesNotExist()
    }

    @Test fun aMessageThatFailsSaysSoOnTheProfile() {
        compose.setContent {
            SlatrixTheme {
                PersonProfileScreen(Person("@mira:example.org", "Mira Chen"), own = false, opening = false,
                    error = "Couldn’t open the conversation.", onMessage = {}, onBack = {})
            }
        }
        compose.onNodeWithText("Couldn’t open the conversation.").assertIsDisplayed()
    }

    private fun message(body: String, html: String? = null) = ConversationMessage(body, "\$$body", "@mira:example.org", "Mira", body,
        html, 1_700_000_000_000L, MessageKind.Text, MessageSendState.Sent, false, "M", 0)
}
