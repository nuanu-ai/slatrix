package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.Invitation
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.ui.account.InvitationScreen
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
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

/** Invitations on Home, and the page that accepts or declines one. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class InvitationScreenTest {
    @get:Rule val compose = createComposeRule()
    private val design = Invitation("!design:example.org", "design", inviter = "Sam Lee")

    // capability: home.invitations
    @Test fun homeListsInvitationsAndOneOpens() {
        val opened = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(loading = false, spacesKnown = true,
                    invitations = listOf(design, Invitation("!harbor:example.org", "Harbor", space = true))), {}, {}, {},
                    onInvitation = { opened += it })
            }
        }
        compose.onNodeWithText("Invitations").assertIsDisplayed()
        compose.onNodeWithText("Harbor").assertIsDisplayed()
        compose.onNodeWithText("design").performClick()
        compose.runOnIdle { assertEquals(listOf(design.id), opened) }
    }

    // capability: home.invitations
    @Test fun anInvitationSaysWhoSentItAndCanBeJoinedOrDeclined() {
        val answers = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme { InvitationScreen(design, responding = false, error = null, onJoin = { answers += "join" }, onDecline = { answers += "decline" }, onBack = {}) }
        }
        compose.onNodeWithText("You’re invited to #design").assertIsDisplayed()
        compose.onNodeWithText("Sam Lee invited you.").assertIsDisplayed()
        compose.onNodeWithText("Decline").performClick()
        compose.onNodeWithText("Join").performClick()
        compose.runOnIdle { assertEquals(listOf("decline", "join"), answers) }
    }

    @Test fun anAnswerOnItsWayHoldsBothButtons() {
        compose.setContent {
            SlatrixTheme {
                InvitationScreen(Invitation("!harbor:example.org", "Harbor", space = true), responding = true, error = null, onJoin = {},
                    onDecline = {}, onBack = {})
            }
        }
        compose.onNodeWithText("Join workspace").assertIsNotEnabled()
        compose.onNodeWithText("Decline").assertIsNotEnabled()
    }
}
