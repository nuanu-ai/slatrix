package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.DayDivider
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

/** Renders conversation rows with every kind of content, at the size of the phone Slack's reference screens come from. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class MessageContentScreenshots(private val dark: Boolean) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        val today = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 9); set(Calendar.MINUTE, 0) }.timeInMillis
        val minute = 60_000L
        fun message(id: String, sender: String, body: String, html: String?, at: Long) =
            ConversationMessage(id, "\$$id", "@${sender.lowercase()}:example.org", sender, body, html, today + at * minute,
                MessageKind.Text, MessageSendState.Sent, sender == "Jordan", sender.take(1), if (sender == "Mira") 2 else 5)
        val rows = listOf(
            DayDivider("today", today),
            message("a", "Mira", "", "<a href=\"https://matrix.to/#/@jordan:example.org\">Jordan Lee</a> " +
                "<a href=\"https://matrix.to/#/@sam:example.org\">Sam</a> I set up a short call today to settle " +
                "<b>priorities</b> for the <i>launch</i>, 14:00 CET.", 0),
            message("b", "Jordan", "", "<blockquote>Can we ship the empty states first?</blockquote>Yes, and the " +
                "<code>onboarding</code> copy is in <a href=\"https://example.org/docs\">the doc</a>.", 6),
            message("c", "Jordan", "", "<p>Plan:</p><ol><li>Fix the <del>banner</del> header</li><li>Ship</li></ol>" +
                "<pre><code>./gradlew assembleRelease</code></pre>", 7).copy(grouped = true, edited = true),
            message("d", "Sam", "This message was deleted", null, 12).copy(kind = MessageKind.Deleted),
        )
        compose.setContent {
            SlatrixTheme(dark = dark) {
                LiveChannelScreen(room, ConversationState(rows, loading = false, hasMore = false),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/MessageContent-${if (dark) "dark" else "light"}.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "dark={0}")
        fun cases(): List<Array<Any>> = listOf(arrayOf(false), arrayOf(true))
    }
}
