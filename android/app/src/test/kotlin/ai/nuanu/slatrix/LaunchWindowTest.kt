package ai.nuanu.slatrix

import android.app.Application
import android.content.ComponentName
import android.view.ContextThemeWrapper
import ai.nuanu.slatrix.core.AccountState
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import androidx.compose.ui.graphics.toArgb
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.NoHandle
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class LaunchWindowTest {
    @Test @Config(qualifiers = "night")
    fun aDarkLaunchOpensOnTheDarkCanvas() = assertLaunchBackground(dark = true)

    @Test @Config(qualifiers = "notnight")
    fun aLightLaunchOpensOnTheLightCanvas() = assertLaunchBackground(dark = false)

    @Test fun launchHoldsSplashUntilSessionRestoresAndInitialRoomsLoad() {
        val connected = AccountState.Connected(Client(NoHandle), "@me:example.org")
        val sampleRoom = RoomSummary("!r:example.org", "Team", false, "", UnreadBadge.None, "T", 0)
        assertFalse(isLaunchReady(AccountState.Connecting(restoring = true), null))
        assertFalse(isLaunchReady(connected, null))
        assertFalse(isLaunchReady(connected, RoomListState(emptyList(), loading = true, spacesKnown = false)))
        assertFalse(isLaunchReady(connected, RoomListState(listOf(sampleRoom), loading = false, spacesKnown = false)))
        assertFalse(isLaunchReady(connected, RoomListState(listOf(sampleRoom), loading = true, spacesKnown = true)))
        assertTrue(isLaunchReady(connected, RoomListState(listOf(sampleRoom), loading = false, spacesKnown = true)))
        assertTrue(isLaunchReady(connected, RoomListState(emptyList(), loading = false, spacesKnown = true)))
        assertTrue(isLaunchReady(AccountState.Connecting(restoring = false), null))
        assertTrue(isLaunchReady(AccountState.SignedOut, null))
        assertTrue(isLaunchReady(AccountState.Failed("Offline", canRetryRestore = true), null))
    }

    private fun assertLaunchBackground(dark: Boolean) {
        val context = RuntimeEnvironment.getApplication()
        val theme = context.packageManager.getActivityInfo(ComponentName(context, MainActivity::class.java), 0).themeResource
        val attributes = ContextThemeWrapper(context, theme).obtainStyledAttributes(intArrayOf(android.R.attr.windowBackground))
        val background = attributes.getColor(0, 0)
        attributes.recycle()
        assertEquals(DesignTokens.colors(dark).getValue("canvas").toArgb(), background)
    }
}
