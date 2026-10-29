package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ActivityItem
import ai.nuanu.slatrix.core.ActivityKind
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.ui.account.ActivityScreen
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** The Activity tab at the size of the Slack reference captures, 1080×2400 at 420 dpi. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class ActivityScreenshots(private val dark: Boolean) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        val day = 86_400_000L
        val oct22 = 1_761_134_400_000L
        fun item(event: String, kind: ActivityKind, body: String, direct: Boolean, at: Long, thread: String? = null) =
            ActivityItem("room $event", "!room:example.org", event, if (direct) "Mira" else "design", direct,
                if (direct) "Mira Chen" else "Jordan Lee", if (direct) "MC" else "JL", if (direct) 2 else 5, body, at, kind, thread)
        val items = listOf(
            item("\$1", ActivityKind.Reaction, "❤️", direct = true, at = oct22),
            item("\$2", ActivityKind.Message, "The call starts in four minutes. I can join today if that suits you.", direct = true, at = oct22 - 1),
            item("\$3", ActivityKind.Mention, "@Alex could you take a look at the launch checklist before Friday?", direct = false, at = oct22 - day),
            item("\$4", ActivityKind.ThreadReply, "Agreed, let's ship after QA signs off.", direct = false, at = oct22 - 2 * day, thread = "\$root"),
        )
        compose.setContent {
            SlatrixTheme(dark = dark) {
                LiveHomeScreen("@alex:example.org", RoomListState(loading = false), {}, {}, {}) { ActivityScreen(items, {}, { _, _ -> }) }
            }
        }
        compose.onAllNodesWithText("Activity").onLast().performClick()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/Activity-${if (dark) "dark" else "light"}.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "dark={0}")
        fun cases(): List<Array<Any>> = listOf(arrayOf(false), arrayOf(true))
    }
}
