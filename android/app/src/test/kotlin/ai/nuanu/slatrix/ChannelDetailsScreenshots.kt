package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ChannelMember
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.NotificationChoice
import ai.nuanu.slatrix.core.NotificationSetting
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ChannelDetailsActions
import ai.nuanu.slatrix.ui.account.ChannelDetailsScreen
import ai.nuanu.slatrix.ui.account.PinnedMessages
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.Density
import com.github.takahirom.roborazzi.captureRoboImage
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
class ChannelDetailsScreenshots(private val dark: Boolean, private val fontScale: Float) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        val room = RoomSummary("!design:example.org", "design", false, "Launch reviews and critique, every Thursday.",
            UnreadBadge.None, "D", 0, memberCount = 4, canEditName = true, canEditTopic = true, canPin = true,
            pinned = listOf("\$a", "\$b"))
        fun message(id: String, sender: String, body: String, minutes: Int) = ConversationMessage(id, "\$$id",
            "@${sender.lowercase()}:example.org", sender, body, null, 1_700_000_000_000L + minutes * 60_000L,
            MessageKind.Text, MessageSendState.Sent, false, sender.take(1), if (sender == "Mira") 2 else 5)
        val pinned = listOf(message("a", "Mira", "Critique moves to Thursdays at 3pm, starting next week.", 0),
            message("b", "Avery", "Brand guidelines live in the shared drive under Design / Brand.", 30))
        val actions = ChannelDetailsActions(
            members = {
                listOf("Avery", "Jordan", "Mira", "Sam").map { ChannelMember("@${it.lowercase()}:example.org", it) }
            },
            notifications = { NotificationSetting(NotificationChoice.Default, NotificationChoice.Mentions) },
            pins = { PinnedMessages(ConversationState(pinned, loading = false)) })
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale)) {
                SlatrixTheme(dark = dark) { ChannelDetailsScreen(room, "@jordan:example.org", actions, {}, {}) {} }
            }
        }
        val name = "${if (dark) "dark" else "light"}-$fontScale"
        compose.onNodeWithText("Default (Mentions and keywords)").assertExists()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/ChannelDetails-$name.png")
        compose.onNodeWithText("Members").performClick()
        compose.onNodeWithText("Avery").assertExists()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/ChannelDetails-members-$name.png")
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Notifications").performClick()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/ChannelDetails-notifications-$name.png")
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Pinned messages").performClick()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/ChannelDetails-pins-$name.png")
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Edit").performClick()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/ChannelDetails-edit-$name.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "dark={0}-font{1}")
        fun cases(): List<Array<Any>> = listOf(arrayOf(false, 1f), arrayOf(true, 1f), arrayOf(false, 1.3f))
    }
}
