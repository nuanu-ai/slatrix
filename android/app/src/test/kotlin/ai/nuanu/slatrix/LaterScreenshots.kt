package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SavedMessage
import ai.nuanu.slatrix.core.SavedPreview
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LaterScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** The Later page, at the size of the Slack reference captures. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class LaterScreenshots(private val dark: Boolean) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        val rooms = listOf(RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0),
            RoomSummary("!wm:example.org", "Wanda Moss", true, "", UnreadBadge.None, "WM", 1))
        val saved = listOf(SavedMessage("!design:example.org", "\$a", 3), SavedMessage("!wm:example.org", "\$b", 2),
            SavedMessage("!design:example.org", "\$c", 1))
        val previews = mapOf(
            "\$a" to SavedPreview("Mira Chen", "The new onboarding flow is up on staging. Would love eyes on the empty states.", 1_761_134_400_000L),
            "\$b" to SavedPreview("Wanda Moss", "Can you look at the release notes before lunch?", 1_761_048_000_000L),
            "\$c" to SavedPreview("Jordan Lee", "Launch review moved to Thursday at 3.", 1_760_961_600_000L),
        )
        compose.setContent { SlatrixTheme(dark = dark) { LaterScreen(saved, rooms, { previews[it.eventId] }, {}, {}) {} } }
        compose.waitForIdle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/Later-${if (dark) "dark" else "light"}.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "dark={0}")
        fun cases(): List<Array<Any>> = listOf(arrayOf(false), arrayOf(true))
    }
}
