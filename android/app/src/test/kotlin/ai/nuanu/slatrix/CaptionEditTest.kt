package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageAttachment
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.account.MessageActions
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.MediaSource
import org.matrix.rustcomponents.sdk.NoHandle
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class CaptionEditTest {
    @get:Rule val compose = createComposeRule()
    private val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
    private val source = object : MediaSource(NoHandle) { override fun url(): String = "mxc://example.org/office" }
    private val edits = mutableListOf<Pair<String?, String?>>()

    private fun media(id: String, caption: String, own: Boolean, name: String = "office.jpg") = ConversationMessage(id, "\$$id",
        if (own) "@me:example.org" else "@mira:example.org", if (own) "Me" else "Mira", caption, null, 1_700_000_000_000L,
        MessageKind.Attachment, MessageSendState.Sent, own, "M", 0,
        attachment = MessageAttachment(MessageAttachment.Kind.Image, name, "image/jpeg", 2_000_000, 1600, 900, source))

    private fun show(vararg messages: ConversationMessage) {
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(messages.toList(), loading = false, hasMore = false),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                    actions = MessageActions(onEditCaption = { message, caption -> edits += message.eventId to caption }))
            }
        }
    }

    // capability: message.edit-caption
    @Test fun yourMediasCaptionChangesFromTheSheetAndEmptyRemovesIt() {
        show(media("p", "Our new office", own = true))
        compose.onNodeWithText("Our new office", useUnmergedTree = true).performTouchInput { longClick() }
        compose.onNodeWithText("Edit caption").performClick()
        compose.onNode(hasSetTextAction() and hasText("Caption", substring = true)).assertTextEquals("Caption", "Our new office").performTextReplacement("Our new office, 3rd floor")
        compose.onNodeWithText("Save").performClick()

        compose.onNodeWithText("Our new office", useUnmergedTree = true).performTouchInput { longClick() }
        compose.onNodeWithText("Edit caption").performClick()
        compose.onNode(hasSetTextAction() and hasText("Caption", substring = true)).performTextClearance()
        compose.onNodeWithText("Save").performClick()
        compose.runOnIdle { assertEquals(listOf("\$p" to "Our new office, 3rd floor", "\$p" to null), edits) }
    }

    @Test fun mediaWithoutACaptionStartsEmptyAndOthersMediaOffersNone() {
        show(media("p", "office.jpg", own = true), media("q", "Their photo", own = false, name = "theirs.jpg"))
        compose.onNodeWithContentDescription("theirs.jpg").performTouchInput { longClick() }
        compose.onAllNodes(isRoot()).assertCountEquals(2)
        compose.onNodeWithText("Edit caption").assertDoesNotExist()
        androidx.test.espresso.Espresso.pressBack()

        compose.onNodeWithContentDescription("office.jpg").performTouchInput { longClick() }
        compose.onNodeWithText("Edit caption").performClick()
        compose.onNode(hasSetTextAction() and hasText("Caption", substring = true)).assertTextEquals("Caption", "")
    }
}
