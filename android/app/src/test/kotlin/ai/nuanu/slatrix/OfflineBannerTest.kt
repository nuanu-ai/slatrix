package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.ProvideOffline
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import kotlinx.coroutines.flow.MutableStateFlow
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
class OfflineBannerTest {
    @get:Rule val compose = createComposeRule()

    // capability: app.offline-banner
    @Test fun theBannerShowsOnceADropLastsFloatsOverHomeAndLeavesWhenTheConnectionReturns() {
        val offline = MutableStateFlow(false)
        val rooms = RoomListState(listOf(RoomSummary("!general:example.org", "general", false, "", UnreadBadge.None, "G", 0)),
            loading = false, spacesKnown = true)
        compose.setContent {
            SlatrixTheme { ProvideOffline(offline) { LiveHomeScreen("@alex:example.org", rooms, {}, {}, {}) } }
        }
        val before = compose.onNodeWithText("general").fetchSemanticsNode().boundsInRoot
        val banner = hasText("You’re offline", substring = true)

        offline.value = true
        compose.waitForIdle()
        compose.onNode(banner).assertDoesNotExist()
        compose.waitUntil(5_000) { compose.onAllNodes(banner).fetchSemanticsNodes().isNotEmpty() }
        assertEquals("Nothing under it moves", before, compose.onNodeWithText("general").fetchSemanticsNode().boundsInRoot)

        offline.value = false
        compose.waitUntil(5_000) { compose.onAllNodes(banner).fetchSemanticsNodes().isEmpty() }
    }
}
