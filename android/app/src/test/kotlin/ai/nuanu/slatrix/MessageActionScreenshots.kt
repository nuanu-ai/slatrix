package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ComposerTarget
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MentionPeople
import ai.nuanu.slatrix.core.MentionPerson
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ComposerActions
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.account.MessageActions
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import com.github.takahirom.roborazzi.captureScreenRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Renders the message sheet, emoji picker and composer bars at the size of the Slack reference screens, for visual review. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class MessageActionScreenshots(private val dark: Boolean) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        val room = RoomSummary("!design:example.org", "design", false, "Launch reviews and critique", UnreadBadge.None, "D", 0)
        fun message(id: String, sender: String, body: String, minutes: Int) = ConversationMessage(id, "\$$id",
            "@${sender.lowercase()}:example.org", sender, body, null, 1_700_000_000_000L + minutes * 60_000L,
            MessageKind.Text, MessageSendState.Sent, sender == "Jordan", sender.take(1), if (sender == "Mira") 2 else 5)
        val rows = listOf(
            message("a", "Mira", "The new onboarding flow is up on staging. Would love eyes on the empty states.", 0),
            message("b", "Jordan", "Looking now. The illustrations read well in dark mode too.", 10).copy(editable = true),
        )
        val actions = MessageActions(quick = listOf("🙂", "❤️", "👍", "💯", "🐛"), recent = listOf("🙂", "❤️", "👍"),
            onReact = { _, _ -> }, link = { "" }, onDelete = {}, onQuote = {}, onEdit = {}, onForward = {}, onPin = { _, _ -> })
        compose.setContent {
            SlatrixTheme(dark = dark) {
                LiveChannelScreen(room, ConversationState(rows, loading = false, hasMore = false), ComposerState(loading = false),
                    {}, {}, {}, {}, {}, {}, {}, {}, actions = actions)
            }
        }
        val theme = if (dark) "dark" else "light"
        compose.onNodeWithText("Looking now.", substring = true).performTouchInput { longClick() }
        compose.waitForIdle()
        captureScreenRoboImage("build/outputs/roborazzi/MessageSheet-$theme.png")
        compose.onNodeWithContentDescription("Add reaction").performClick()
        compose.waitUntil { compose.onAllNodes(hasContentDescription("grinning face")).fetchSemanticsNodes().isNotEmpty() }
        captureScreenRoboImage("build/outputs/roborazzi/EmojiPicker-$theme.png")
    }

    @Test fun composerBars() {
        val room = RoomSummary("!design:example.org", "design", false, "Launch reviews and critique", UnreadBadge.None, "D", 0)
        val composer = mutableStateOf(ComposerState(loading = false,
            target = ComposerTarget.Reply("\$a", "Mira", "The new onboarding flow is up on staging. Would love eyes on the empty states.")))
        compose.setContent {
            SlatrixTheme(dark = dark) {
                LiveChannelScreen(room, ConversationState(emptyList(), loading = false, hasMore = false), composer.value,
                    {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        val theme = if (dark) "dark" else "light"
        captureScreenRoboImage("build/outputs/roborazzi/ReplyBar-$theme.png")
        compose.runOnIdle { composer.value = ComposerState("Looking now.", loading = false, target = ComposerTarget.Edit("\$b", "Looking now.")) }
        compose.waitForIdle()
        captureScreenRoboImage("build/outputs/roborazzi/Editing-$theme.png")
    }

    @Test fun composerMentionsAndAttachments() {
        val room = RoomSummary("!design:example.org", "design", false, "Launch reviews and critique", UnreadBadge.None, "D", 0)
        val text = mutableStateOf("")
        val people = MentionPeople(listOf(MentionPerson("@mira:example.org", "Mira Chen"), MentionPerson("@miles:example.org", "Miles Park"),
            MentionPerson("@jordan:example.org", "Jordan Lee")), offersRoom = true)
        compose.setContent {
            SlatrixTheme(dark = dark) {
                LiveChannelScreen(room, ConversationState(emptyList(), loading = false, hasMore = false),
                    ComposerState(text.value, loading = false), { text.value = it }, {}, {}, {}, {}, {}, {}, {},
                    composerActions = ComposerActions(people = people, onAttach = {}))
            }
        }
        val theme = if (dark) "dark" else "light"
        captureScreenRoboImage("build/outputs/roborazzi/Composer-$theme.png")
        compose.onNodeWithContentDescription("Message #design").performTextInput("Can you check this @mi")
        compose.onNodeWithText("Miles Park").assertExists()
        captureScreenRoboImage("build/outputs/roborazzi/Mentions-$theme.png")
        compose.runOnIdle { text.value = "" }
        compose.onNodeWithContentDescription("Attachments").performClick()
        compose.onNodeWithText("Files").assertExists()
        captureScreenRoboImage("build/outputs/roborazzi/Attachments-$theme.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "dark={0}")
        fun cases(): List<Array<Any>> = listOf(arrayOf(false), arrayOf(true))
    }
}
