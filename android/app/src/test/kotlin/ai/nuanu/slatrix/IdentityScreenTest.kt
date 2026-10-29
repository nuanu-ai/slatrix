package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.IdentityPhase
import ai.nuanu.slatrix.core.IdentityState
import ai.nuanu.slatrix.core.IdentityStatus
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ConnectedAccountScreen
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.ComponentActivity
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.semantics.SemanticsActions
import org.junit.Rule
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class IdentityScreenTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun conversationsStayHiddenUntilIdentityIsConfirmed() {
        val identity = mutableStateOf(IdentityState(status = IdentityStatus.Unverified, phase = IdentityPhase.ChooseMethod))
        val rooms = RoomListState(listOf(RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)), loading = false)
        compose.setContent {
            SlatrixTheme {
                ConnectedAccountScreen(identity.value, {}, {}, {}, {}, {}, {}, {}) {
                    LiveHomeScreen("@alex:example.org", rooms, {}, {}, {})
                }
            }
        }
        compose.onNodeWithText("Confirm it’s you").assertExists()
        compose.onNodeWithText("Team").assertDoesNotExist()
        compose.runOnIdle { identity.value = identity.value.copy(status = IdentityStatus.Verified) }
        compose.onNodeWithText("Team").assertExists()
    }

    @Test fun aDeviceStillCheckingItsIdentityOpensWithoutTheConfirmationScreen() {
        val rooms = RoomListState(listOf(RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)), loading = false)
        compose.setContent {
            SlatrixTheme {
                ConnectedAccountScreen(IdentityState(), {}, {}, {}, {}, {}, {}, {}) {
                    LiveHomeScreen("@alex:example.org", rooms, {}, {}, {})
                }
            }
        }
        compose.onNodeWithText("Team").assertExists()
        compose.onNodeWithText("Confirm it’s you").assertDoesNotExist()
    }

    @Test fun aDeviceWhoseIdentityCheckFailedShowsTheConfirmationScreenToRetry() {
        compose.setContent {
            SlatrixTheme {
                ConnectedAccountScreen(IdentityState(phase = IdentityPhase.Failed, error = "Couldn’t check this device. Try again."),
                    {}, {}, {}, {}, {}, {}, {}) {}
            }
        }
        compose.onNodeWithText("Confirm it’s you").assertExists()
    }

    @Test fun aRecoveryKeyScrollsHorizontallyWithoutWrapping() {
        compose.setContent {
            SlatrixTheme {
                ConnectedAccountScreen(IdentityState(IdentityStatus.Unverified, IdentityPhase.ChooseMethod, recoveryAvailable = true),
                    {}, {}, {}, {}, {}, {}, {}) {}
            }
        }
        compose.onNodeWithText("Use recovery key").performClick()
        val field = compose.onNode(hasSetTextAction())
        field.performTextInput("EsT1 abcd efgh ijkm nopq rstu vwxy z123 4567 89AB CDEF GHJK")
        field.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { action ->
            val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            action(layouts)
            assertEquals("A recovery key is one horizontally scrolling line", 1, layouts.single().lineCount)
        }
    }
}
