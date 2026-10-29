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
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.captureScreenRoboImage
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import java.util.Calendar
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class LiveChannelScreenshots(private val dark: Boolean, private val fontScale: Float) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        val room = RoomSummary("!design:example.org", "design", false, "Launch reviews and critique", UnreadBadge.None, "D", 0)
        val today = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 9); set(Calendar.MINUTE, 0) }.timeInMillis
        val minute = 60_000L
        fun message(id: String, sender: String, body: String, at: Long, state: MessageSendState = MessageSendState.Sent) =
            ConversationMessage(id, "\$$id", "@${sender.lowercase()}:example.org", sender, body, null, at,
                MessageKind.Text, state, sender == "Jordan", sender.take(1), if (sender == "Mira") 2 else 5)
        val messages = listOf(
            DayDivider("yesterday", today - 24 * 60 * minute),
            message("a", "Mira", "Morning! The new onboarding flow is up on staging.", today - 24 * 60 * minute),
            message("b", "Mira", "Would love eyes on the empty states.", today - 24 * 60 * minute + minute).copy(grouped = true),
            DayDivider("today", today),
            message("c", "Jordan", "Looking now.", today),
            message("d", "Jordan", "The illustrations read well in dark mode too.", today + 2 * minute).copy(grouped = true),
            message("e", "Jordan", "One more pass after lunch.", today + 3 * minute, MessageSendState.Failed)
                .copy(grouped = true, transactionId = "txn", canRetry = true),
        )
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale)) {
                SlatrixTheme(dark = dark) {
                    LiveChannelScreen(room, ConversationState(messages, loading = false, hasMore = false),
                        ComposerState(loading = false), {}, {}, {}, {}, {}, {})
                }
            }
        }
        val theme = if (dark) "dark" else "light"
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/LiveChannel-$theme-$fontScale.png")
        compose.onNodeWithText("One more pass after lunch.").performTouchInput { longClick() }
        compose.onNodeWithText("Delete message").assertIsDisplayed()
        captureScreenRoboImage("build/outputs/roborazzi/LiveChannel-sheet-$theme-$fontScale.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "dark={0}-font{1}")
        fun cases(): List<Array<Any>> = listOf(arrayOf(false, 1f), arrayOf(true, 1f), arrayOf(false, 1.3f))
    }
}
