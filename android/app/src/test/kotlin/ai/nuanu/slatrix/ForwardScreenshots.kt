package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ForwardScreen
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

/** The forward page, at the size of the Slack reference captures. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class ForwardScreenshots(private val dark: Boolean) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        val design = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        val rooms = listOf(design,
            RoomSummary("!general:example.org", "general", false, "", UnreadBadge.None, "G", 2),
            RoomSummary("!plans:example.org", "launch-plans", false, "", UnreadBadge.None, "L", 5, isPrivate = true),
            RoomSummary("!wm:example.org", "Wanda Moss", true, "", UnreadBadge.None, "WM", 1),
            RoomSummary("!n:example.org", "Nina", true, "", UnreadBadge.None, "N", 3))
        val message = ConversationMessage("m", "\$m", "@mira:example.org", "Mira Chen",
            "The new onboarding flow is up on staging. Would love eyes on the empty states.", null, 1_700_000_000_000L,
            MessageKind.Text, MessageSendState.Sent, false, "MC", 2)
        compose.setContent { SlatrixTheme(dark = dark) { ForwardScreen(message, design, rooms, {}) {} } }
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/Forward-${if (dark) "dark" else "light"}.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "dark={0}")
        fun cases(): List<Array<Any>> = listOf(arrayOf(false), arrayOf(true))
    }
}
