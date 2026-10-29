package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
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
class LiveWorkspaceTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun anUnreadRoomOpensFromTheLiveHome() {
        val rooms = RoomListState(listOf(RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.Count("3"), "T", 0)), loading = false)
        var opened: String? = null
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", rooms, { opened = it }, {}, {}) } }
        compose.onNodeWithText("3").assertExists()
        compose.onNodeWithText("Team").performClick()
        compose.runOnIdle { assertEquals("!team:example.org", opened) }
    }
}
