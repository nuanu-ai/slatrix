package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ComposerStyle
import ai.nuanu.slatrix.ui.account.ComposerActions
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.isToggleable
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
        // The moment it opens: the channel's root, with the replies still on their way.
        var state by mutableStateOf(ConversationState(rows.take(1), loading = false, hasMore = true))
        var draft by mutableStateOf(ComposerState(loading = false))
        compose.setContent {
            SlatrixTheme(dark = dark) {
                LiveChannelScreen(room, state, draft,
                    {}, {}, {}, {}, {}, {}, {}, {}, threadRoot = "\$root", composerActions = ComposerActions(onFormat = { _, _, _, _ -> }))
            }
        }
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/Thread-opening-${if (dark) "dark" else "light"}.png")
        state = ConversationState(rows, loading = false, hasMore = false)
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/Thread-${if (dark) "dark" else "light"}.png")
        // Slack's Aa open over a draft with each kind of format.
        val text = "Agenda for the call\nreview the launch list\nsee docs"
        draft = ComposerState(text, loading = false, styles = listOf(
            ComposerStyle(0, 6, ComposerStyle.Kind.Bold), ComposerStyle(19, 42, ComposerStyle.Kind.Bullet),
            ComposerStyle(38, 42, ComposerStyle.Kind.Italic), ComposerStyle(47, 51, ComposerStyle.Kind.Link, "https://example.org")))
        compose.onNode(hasContentDescription("Add a reply") and hasSetTextAction()).performClick()
        compose.onNodeWithContentDescription("Formatting").performClick()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/Thread-formatting-${if (dark) "dark" else "light"}.png")
    }

    /** The open composer of a private channel's thread, with Slack's "Also send to" over the field. */
    @Test fun renderAlsoSendToChannel() {
        val room = RoomSummary("!ops:example.org", "launch-ops", false, "", UnreadBadge.None, "L", 0, isPrivate = true)
        val root = ConversationMessage("root", "\$root", "@mira:example.org", "Mira",
            "Booked a short call today to set priorities for the launch tasks at 14:00.", null,
            Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 12); set(Calendar.MINUTE, 7) }.timeInMillis,
            MessageKind.Text, MessageSendState.Sent, false, "M", 2)
        var draft by mutableStateOf(ComposerState(loading = false))
        compose.setContent {
            SlatrixTheme(dark = dark) {
                LiveChannelScreen(room, ConversationState(listOf(root), loading = false, hasMore = false), draft,
                    {}, {}, {}, {}, {}, {}, {}, {}, threadRoot = "\$root", composerActions = ComposerActions(onAttach = {},
                        onFormat = { _, _, _, _ -> }, onAlsoToChannel = { draft = draft.copy(alsoToChannel = it) }))
            }
        }
        val theme = if (dark) "dark" else "light"
        compose.onNode(hasContentDescription("Add a reply") and hasSetTextAction()).performClick()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/Thread-also-send-$theme.png")
        compose.onNode(isToggleable()).performClick()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/Thread-also-send-checked-$theme.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "dark={0}")
        fun cases(): List<Array<Any>> = listOf(arrayOf(false), arrayOf(true))
    }
}
