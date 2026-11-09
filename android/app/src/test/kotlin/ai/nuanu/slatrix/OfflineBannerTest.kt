package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.LiveYouScreen
import ai.nuanu.slatrix.ui.account.ProvideConnection
import ai.nuanu.slatrix.core.ConnectionState
import ai.nuanu.slatrix.ui.designsystem.AppColors
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.onNodeWithContentDescription
import kotlin.math.abs
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

    // capability: app.own-presence
    @Test fun yourOwnDotIsGreenWhileConnectedAndHollowOnceTheConnectionIsLost() {
        val connection = MutableStateFlow(ConnectionState.Connected)
        lateinit var view: View
        lateinit var colors: AppColors
        compose.setContent {
            view = LocalView.current
            SlatrixTheme {
                colors = SlatrixTheme.colors
                ProvideConnection(connection) { LiveHomeScreen("@alex:example.org", RoomListState(loading = false), {}, {}, {}) }
            }
        }
        val you = compose.onNodeWithContentDescription("You").fetchSemanticsNode().boundsInRoot
        // The dot's middle sits this far right and down from the avatar's.
        val reach = with(compose.density) { UiMetrics.HeaderAvatar.toPx() } * 0.42f
        fun dot(): Color {
            compose.waitForIdle()
            val picture = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
            return Color(picture.getPixel((you.center.x + reach).toInt(), (you.center.y + reach).toInt()))
        }
        fun near(a: Color, b: Color) = listOf(a.red - b.red, a.green - b.green, a.blue - b.blue).all { abs(it) < 0.02f }
        assertTrue("Green while connected", near(colors.presenceActive, dot()))
        connection.value = ConnectionState.Offline
        compose.mainClock.advanceTimeBy(UiMetrics.ConnectionNoticeMillis + 100)
        assertTrue("Hollow once the connection is lost", !near(colors.presenceActive, dot()))
        connection.value = ConnectionState.Connected
        compose.mainClock.advanceTimeBy(100)
        assertTrue("Green again once it's back", near(colors.presenceActive, dot()))
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
