package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.LiveYouScreen
import ai.nuanu.slatrix.ui.account.ProvideConnection
import ai.nuanu.slatrix.core.ConnectionState
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import kotlinx.coroutines.flow.MutableStateFlow
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
class OfflineBannerTest {
    @get:Rule val compose = createComposeRule()

    // capability: app.connection-status
    @Test fun youShowsTheCurrentConnectionEvenWhenThereIsNoBanner() {
        val connection = MutableStateFlow(ConnectionState.Connected)
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 2f)) {
                SlatrixTheme { ProvideConnection(connection, {}) { LiveYouScreen("@alex:example.org", "Alex", {}, {}, onBack = {}) } }
            }
        }
        compose.onNodeWithText("Connected").assertExists()
        val preferences = compose.onNodeWithText("Preferences").fetchSemanticsNode().boundsInRoot
        connection.value = ConnectionState.Reconnecting
        compose.waitUntil(5_000) { compose.onAllNodes(hasText("Reconnecting…")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Connected").assertDoesNotExist()
        assertEquals("The connection row stays still at large text sizes", preferences,
            compose.onNodeWithText("Preferences").fetchSemanticsNode().boundsInRoot)
    }

    @Test fun waitingForTheServerSaysReconnectingAndOffersRetry() {
        val connection = MutableStateFlow(ConnectionState.Reconnecting)
        var retried = false
        val rooms = RoomListState(listOf(RoomSummary("!general:example.org", "general", false, "", UnreadBadge.None, "G", 0)),
            loading = false, spacesKnown = true)
        compose.setContent {
            SlatrixTheme { ProvideConnection(connection, { retried = true }) { LiveHomeScreen("@alex:example.org", rooms, {}, {}, {}) } }
        }
        val reconnecting = hasText("Reconnecting…")
        compose.waitUntil(5_000) { compose.onAllNodes(reconnecting).fetchSemanticsNodes().isNotEmpty() }
        compose.onNode(hasText("You’re offline", substring = true)).assertDoesNotExist()
        compose.onNodeWithText("Retry").performClick()
        assertTrue(retried)
        connection.value = ConnectionState.Connected
        compose.waitUntil(5_000) { compose.onAllNodes(reconnecting).fetchSemanticsNodes().isEmpty() }
    }

    // capability: app.offline-banner
    @Test fun theBannerShowsOnceADropLastsFloatsOverHomeAndLeavesWhenTheConnectionReturns() {
        val offline = MutableStateFlow(ConnectionState.Connected)
        val rooms = RoomListState(listOf(RoomSummary("!general:example.org", "general", false, "", UnreadBadge.None, "G", 0)),
            loading = false, spacesKnown = true)
        compose.setContent {
            SlatrixTheme { ProvideConnection(offline) { LiveHomeScreen("@alex:example.org", rooms, {}, {}, {}) } }
        }
        val before = compose.onNodeWithText("general").fetchSemanticsNode().boundsInRoot
        val banner = hasText("You’re offline", substring = true)

        offline.value = ConnectionState.Offline
        compose.waitForIdle()
        compose.onNode(banner).assertDoesNotExist()
        compose.waitUntil(5_000) { compose.onAllNodes(banner).fetchSemanticsNodes().isNotEmpty() }
        assertEquals("Nothing under it moves", before, compose.onNodeWithText("general").fetchSemanticsNode().boundsInRoot)

        offline.value = ConnectionState.Connected
        compose.waitUntil(5_000) { compose.onAllNodes(banner).fetchSemanticsNodes().isEmpty() }
    }
}
