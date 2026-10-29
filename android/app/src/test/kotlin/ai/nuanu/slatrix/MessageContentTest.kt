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
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** What a conversation row shows of a message. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class MessageContentTest {
    @get:Rule val compose = createComposeRule()
    private val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)

    private fun show(vararg messages: ConversationMessage) {
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(messages.toList(), loading = false, hasMore = false),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
    }

    private fun SemanticsNodeInteraction.text(): AnnotatedString =
        fetchSemanticsNode().config[SemanticsProperties.Text].single()

    // capability: message.rich-text
    @Test fun formattedTextShowsItsStylesNotItsMarkup() {
        show(message("**Ship** it", html = "<strong>Ship</strong> it"))
        val text = compose.onNodeWithText("Ship it", useUnmergedTree = true).text()
        assertEquals(listOf("Ship"), text.spanStyles.filter { it.item.fontWeight == FontWeight.Bold }.map { text.substring(it.start, it.end) })
    }

    // capability: message.rich-text
    @Test fun aListItemsTextAfterANestedListLinesUpWithTheItem() {
        show(message("one inner tail", html = "<ul><li>one<ul><li>inner</li></ul>tail</li></ul><blockquote>said<ul><li>this</li></ul></blockquote>"))
        fun left(text: String) = compose.onNodeWithText(text, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot.left
        assertEquals(left("one"), left("tail"))
        assertTrue("The nested item sits further in", left("inner") > left("one"))
        assertTrue("A list in a quote sits past the quote's bar", left("this") > left("one"))
    }

    // capability: message.edited
    @Test fun anEditedMessageEndsWithSlacksEditedMark() {
        show(message("Fixed the typo").copy(edited = true))
        compose.onNodeWithText("Fixed the typo (edited)", useUnmergedTree = true).assertExists()
    }

    // capability: message.deleted
    @Test fun aDeletedMessageReadsAsSlacksInItalics() {
        show(message("This message was deleted").copy(kind = MessageKind.Deleted))
        val text = compose.onNodeWithText("This message was deleted.", useUnmergedTree = true).text()
        assertEquals(FontStyle.Italic, text.spanStyles.single().item.fontStyle)
    }

    private fun message(body: String, html: String? = null) = ConversationMessage(body, "\$$body", "@mira:example.org", "Mira", body,
        html, 1_700_000_000_000L, MessageKind.Text, MessageSendState.Sent, false, "M", 0)
}
