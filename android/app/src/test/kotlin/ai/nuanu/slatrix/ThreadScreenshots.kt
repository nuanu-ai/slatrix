package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import java.util.Calendar
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** The thread page at the size of the Slack reference captures, 1080×2400 at 420 dpi. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class ThreadScreenshots(private val dark: Boolean) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        val noon = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 12); set(Calendar.MINUTE, 7) }.timeInMillis
        fun message(id: String, sender: String, body: String, at: Long) = ConversationMessage(id, "\$$id",
            "@${sender.lowercase()}:example.org", sender, body, null, at, MessageKind.Text, MessageSendState.Sent, false,
            sender.take(1), if (sender == "Mira") 2 else 5)
        val rows = listOf(
            message("root", "Mira", "Booked a short call today to set priorities for the launch tasks at 14:00.", noon),
            message("a", "Jordan", "Works for me.", noon + 4 * 60_000L),
            message("b", "Mira", "Great, sending the invite now.", noon + 9 * 60_000L),
        )
        compose.setContent {
            SlatrixTheme(dark = dark) {
                LiveChannelScreen(room, ConversationState(rows, loading = false, hasMore = false), ComposerState(loading = false),
                    {}, {}, {}, {}, {}, {}, {}, {}, threadRoot = "\$root")
            }
        }
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/Thread-${if (dark) "dark" else "light"}.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "dark={0}")
        fun cases(): List<Array<Any>> = listOf(arrayOf(false), arrayOf(true))
    }
}
