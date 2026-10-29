package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ActivityItem
import ai.nuanu.slatrix.core.ActivityKind
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ActivityScreen
import ai.nuanu.slatrix.ui.account.AvatarLoader
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.LocalAvatarLoader
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.performClick
import com.github.takahirom.roborazzi.captureScreenRoboImage
import java.util.Calendar
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Renders a conversation and Activity with senders' pictures loaded, at the size of the Slack reference captures
 * (1080×2400 at 420 dpi), so each can sit next to its reference. The pictures are gradients standing in for photos.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class SenderAvatarScreenshots {
    @get:Rule val compose = createComposeRule()

    private val pictures = object : AvatarLoader {
        override suspend fun load(url: String, sizePx: Int): ImageBitmap = picture(url.substringAfterLast('/'))
    }

    @Test fun conversation() {
        val room = RoomSummary("!design:example.org", "design", false, "Launch reviews", UnreadBadge.None, "D", 0, isPrivate = true)
        val nine = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 9); set(Calendar.MINUTE, 0) }.timeInMillis
        fun message(id: String, sender: String, body: String, at: Long) = ConversationMessage(id, "\$$id", "@${sender.lowercase()}:example.org",
            sender, body, null, at, MessageKind.Text, MessageSendState.Sent, false, sender.take(1), if (sender == "Mira") 2 else 5,
            avatarUrl = "mxc://example.org/${sender.lowercase()}")
        val rows = listOf(
            message("a", "Mira", "Booked a short call today to set priorities for the launch tasks at 14:00.", nine),
            message("b", "Mira", "Agenda is in the doc.", nine + 60_000).copy(grouped = true),
            message("c", "Jordan", "Works for me, I'll bring the checklist.", nine + 3_600_000),
        )
        compose.setContent {
            CompositionLocalProvider(LocalAvatarLoader provides pictures) {
                SlatrixTheme(dark = false) {
                    LiveChannelScreen(room, ConversationState(rows, loading = false, hasMore = false), ComposerState(loading = false),
                        {}, {}, {}, {}, {}, {}, {}, {})
                }
            }
        }
        compose.waitForIdle()
        captureScreenRoboImage("build/outputs/roborazzi/SenderAvatars-conversation.png")
    }

    @Test fun activity() {
        val nine = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 9); set(Calendar.MINUTE, 0) }.timeInMillis
        val items = listOf(
            ActivityItem("1", "!mira:example.org", "\$1", "Mira", true, "Mira Chen", "MC", 2, "Can you join the call at 14:00?", nine,
                ActivityKind.Message, null, avatarUrl = "mxc://example.org/mira"),
            ActivityItem("2", "!design:example.org", "\$2", "design", false, "Jordan Lee", "JL", 5,
                "@Alex could you take a look at the launch checklist?", nine - 86_400_000, ActivityKind.Mention, null,
                avatarUrl = "mxc://example.org/jordan"),
        )
        compose.setContent {
            CompositionLocalProvider(LocalAvatarLoader provides pictures) {
                SlatrixTheme(dark = false) {
                    LiveHomeScreen("@alex:example.org", RoomListState(loading = false), {}, {}, {}) { ActivityScreen(items, {}, { _, _ -> }) {} }
                }
            }
        }
        compose.onAllNodesWithText("Activity").onLast().performClick()
        compose.waitForIdle()
        captureScreenRoboImage("build/outputs/roborazzi/SenderAvatars-activity.png")
    }

    private fun picture(name: String): ImageBitmap {
        val size = 120
        val (from, to) = if (name == "mira") 0xff2b2d42.toInt() to 0xffd9a38a.toInt() else 0xff355070.toInt() to 0xffeaac8b.toInt()
        return Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also {
            Canvas(it).drawRect(0f, 0f, size.toFloat(), size.toFloat(),
                Paint().apply { shader = LinearGradient(0f, 0f, size.toFloat(), size.toFloat(), from, to, Shader.TileMode.CLAMP) })
        }.asImageBitmap()
    }
}
