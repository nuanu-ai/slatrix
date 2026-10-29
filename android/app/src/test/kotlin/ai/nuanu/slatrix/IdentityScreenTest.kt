package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.IdentityPhase
import ai.nuanu.slatrix.core.IdentityState
import ai.nuanu.slatrix.core.IdentityStatus
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ConnectedAccountScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.ComponentActivity
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import org.junit.Rule
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
        val identity = mutableStateOf(IdentityState(phase = IdentityPhase.ChooseMethod))
        val rooms = RoomListState(listOf(RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)), loading = false)
        compose.setContent {
            SlatrixTheme {
                ConnectedAccountScreen(identity.value, rooms, {}, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNodeWithText("Confirm it’s you").assertExists()
        compose.onNodeWithText("Team").assertDoesNotExist()
        compose.runOnIdle { identity.value = identity.value.copy(status = IdentityStatus.Verified) }
        compose.onNodeWithText("Team").assertExists()
    }
}
