package ai.nuanu.slatrix

import ai.nuanu.slatrix.ui.account.OfflineBanner
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
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
    @Test fun theBannerWaitsOutAShortDropFloatsOverTheScreenAndLeavesWhenTheConnectionReturns() {
        val offline = mutableStateOf(false)
        compose.mainClock.autoAdvance = false
        compose.setContent {
            SlatrixTheme {
                Box {
                    Text("Channels")
                    OfflineBanner(offline.value)
                }
            }
        }
        compose.mainClock.advanceTimeBy(100)
        val before = compose.onNodeWithText("Channels").fetchSemanticsNode().boundsInRoot

        offline.value = true
        compose.mainClock.advanceTimeBy(1_500)
        compose.onNodeWithText("You’re offline", substring = true).assertDoesNotExist()
        compose.mainClock.advanceTimeBy(1_000)
        compose.onNodeWithText("You’re offline", substring = true).assertExists()
        assertEquals("Nothing under it moves", before, compose.onNodeWithText("Channels").fetchSemanticsNode().boundsInRoot)

        offline.value = false
        compose.mainClock.advanceTimeBy(1_000)
        compose.onNodeWithText("You’re offline", substring = true).assertDoesNotExist()
    }
}
