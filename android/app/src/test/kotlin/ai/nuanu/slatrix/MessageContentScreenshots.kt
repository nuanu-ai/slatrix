package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.DayDivider
import ai.nuanu.slatrix.core.MessageAttachment
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageReaction
import ai.nuanu.slatrix.core.MessageThread
import ai.nuanu.slatrix.core.ReplyPreview
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import android.graphics.Bitmap
import java.io.ByteArrayOutputStream
import org.matrix.rustcomponents.sdk.MediaSource
import org.matrix.rustcomponents.sdk.NoHandle
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
        val source = object : MediaSource(NoHandle) { override fun url(): String = "mxc://example.org/office" }
        val png = ByteArrayOutputStream().also {
            Bitmap.createBitmap(1600, 900, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.rgb(96, 125, 139)) }
                .compress(Bitmap.CompressFormat.PNG, 100, it)
        }.toByteArray()
        fun message(id: String, sender: String, body: String, html: String?, at: Long) =
            ConversationMessage(id, "\$$id", "@${sender.lowercase()}:example.org", sender, body, html, today + at * minute,
                MessageKind.Text, MessageSendState.Sent, sender == "Jordan", sender.take(1), if (sender == "Mira") 2 else 5)
        val rows = listOf(
            DayDivider("today", today),
            message("a", "Mira", "", "<a href=\"https://matrix.to/#/@jordan:example.org\">Jordan Lee</a> " +
                "<a href=\"https://matrix.to/#/@sam:example.org\">Sam</a> I set up a short call today to settle " +
                "<b>priorities</b> for the <i>launch</i>, 14:00 CET.", 0).copy(reactions = listOf(
                MessageReaction("👍", 2, true, listOf("@jordan:example.org", "@sam:example.org")),
                MessageReaction("👀", 1, false, listOf("@sam:example.org")))),
            message("b", "Jordan", "", "<blockquote>Can we ship the empty states first?</blockquote>Yes, and the " +
                "<code>onboarding</code> copy is in <a href=\"https://example.org/docs\">the doc</a>.", 6)
                .copy(thread = MessageThread(3, "Sam", today + 40 * minute),
                    replyTo = ReplyPreview("\$a", ReplyPreview.State.Ready, "Mira", "@Jordan Lee @Sam I set up a short call today")),
            message("c", "Jordan", "", "<p>Plan:</p><ol><li>Fix the <del>banner</del> header</li><li>Ship</li></ol>" +
                "<pre><code>./gradlew assembleRelease</code></pre>", 7).copy(grouped = true, edited = true),
            message("d", "Sam", "This message was deleted", null, 12).copy(kind = MessageKind.Deleted),
            message("e", "Mira", "office.jpg", null, 20).copy(kind = MessageKind.Attachment, attachment = MessageAttachment(
                MessageAttachment.Kind.Image, "office.jpg", "image/jpeg", 2_000_000, 1600, 900, source)),
            message("f", "Mira", "Q3 report.pdf", null, 21).copy(kind = MessageKind.Attachment, grouped = true,
                attachment = MessageAttachment(MessageAttachment.Kind.File, "Q3 report.pdf", "application/pdf", 250_000, null, null, source)),
        )
        compose.setContent {
            SlatrixTheme(dark = dark) {
                LiveChannelScreen(room, ConversationState(rows, loading = false, hasMore = false, ownUserId = "@jordan:example.org"),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {}, loadPicture = { _, _, _, _ -> png })
            }
        }
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/MessageContent-${if (dark) "dark" else "light"}.png")
    }

    /** The layout of Slack's channel reference screen, in fictional words: a quote, reactions, a day divider and pills. */
    @Test fun renderSlackLayout() {
        if (dark) return
        val room = RoomSummary("!ops:example.org", "ops-review", false, "", UnreadBadge.None, "O", 0)
        val day = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -3); set(Calendar.HOUR_OF_DAY, 14); set(Calendar.MINUTE, 9) }.timeInMillis
        fun message(id: String, sender: String, html: String, at: Long) =
            ConversationMessage(id, "\$$id", "@${sender.lowercase().replace(' ', '.')}:example.org", sender, "", html, at,
                MessageKind.Text, MessageSendState.Sent, false, sender.split(' ').joinToString("") { it.take(1) }, 3)
        fun pill(id: String, name: String) = "<a href=\"https://matrix.to/#/@$id:example.org\">$name</a>"
        val rows = listOf(
            message("a", "Nora Field", "We went through the vendor list and the audit forms, and we are coming back with a " +
                "short note on what is ready and what is still missing.", day - 30 * 60_000L).copy(reactions = listOf(
                MessageReaction("👍", 2, false, listOf("@sam:example.org", "@lee:example.org")))),
            message("b", "Nora Field", pill("nora", "Nora Field") + " Hi! Sharing what we have so far.<ol><li>Cases over the " +
                "threshold this quarter</li></ol>", day).copy(replyTo = ReplyPreview("\$x", ReplyPreview.State.Ready, "Sam Reyes",
                "Could you send the numbers before the review?"), reactions = listOf(
                MessageReaction("👀", 2, true, listOf("@sam:example.org", "@me:example.org")))),
            DayDivider("next", day + 22 * 3_600_000L),
            message("c", "Nora Field", pill("alex", "Alex Moreau") + " " + pill("lena", "Lena") + " I booked a short call today to " +
                "set priorities for the open tasks at 14:00 CET / 15:00 local.", day + 22 * 3_600_000L).copy(reactions = listOf(
                MessageReaction("👌", 1, false, listOf("@lena:example.org")))),
        )
        compose.setContent {
            SlatrixTheme(dark = false) {
                LiveChannelScreen(room, ConversationState(rows, loading = false, hasMore = true, ownUserId = "@me:example.org"),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/MessageContent-slack-layout.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "dark={0}")
        fun cases(): List<Array<Any>> = listOf(arrayOf(false), arrayOf(true))
    }
}
