package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageReaction
import ai.nuanu.slatrix.core.MessageThread
import ai.nuanu.slatrix.core.ReplyPreview
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.account.MessageActions
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
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

    private var toggled: Pair<ConversationMessage, String>? = null
    private var thread: String? = null
    private var jumped: String? = null

    private fun show(vararg messages: ConversationMessage) {
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(messages.toList(), loading = false, hasMore = false, ownUserId = "@me:example.org"),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                    onOpenThread = { thread = it }, actions = MessageActions(onReact = { message, key -> toggled = message to key }),
                    onOpenMessage = { jumped = it })
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

    // capability: message.mention-pills
    @Test fun aMentionOfYouStandsOutFromOtherMentions() {
        show(message("@me @sam", html = "<a href=\"https://matrix.to/#/@me:example.org\">Me</a> " +
            "<a href=\"https://matrix.to/#/@sam:example.org\">Sam</a>"))
        val text = compose.onNodeWithText("@Me @Sam", useUnmergedTree = true).text()
        fun fill(name: String) = text.spanStyles.single { text.substring(it.start, it.end) == name }.item.background
        val tokens = DesignTokens.colors(false, SidebarPalette.Aubergine)
        assertEquals(tokens.getValue("mentionYouFill"), fill("@Me"))
        assertEquals(tokens.getValue("mentionFill"), fill("@Sam"))
    }

    // capability: message.reactions.show
    // capability: message.reactions.toggle
    @Test fun reactionsShowAsChipsWithYoursSelectedAndATapTogglesOne() {
        val shipped = message("Ship it").copy(reactions = listOf(
            MessageReaction("👍", 2, true, listOf("@mira:example.org", "@me:example.org")),
            MessageReaction("🎉", 1, false, listOf("@sam:example.org")),
        ))
        show(shipped)
        compose.onNode(hasText("👍") and hasText("2")).assertIsSelected()
        compose.onNode(hasText("🎉") and hasText("1")).assertIsNotSelected().performClick()
        compose.runOnIdle { assertEquals(shipped to "🎉", toggled) }
    }

    // capability: message.reactions.show
    @Test fun longPressingAReactionShowsWhoReacted() {
        show(message("Ship it").copy(reactions = listOf(
            MessageReaction("👍", 3, true, listOf("@mira:example.org", "@me:example.org", "@sam:example.org")),
        )))
        compose.onNode(hasText("👍") and hasText("3")).performTouchInput { longClick() }
        compose.onNodeWithText("Mira, You and sam", substring = true).assertIsDisplayed()
    }

    // capability: message.thread-summary
    @Test fun aThreadRootShowsItsRepliesAndOpensTheThread() {
        show(message("Plan?").copy(thread = MessageThread(3, "Sam Okafor", System.currentTimeMillis() - 2 * 3_600_000L)))
        compose.onNodeWithText("3 replies", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("Last reply 2 hours ago", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("3 replies", useUnmergedTree = true).performClick()
        compose.runOnIdle { assertEquals("\$Plan?", thread) }
    }

    // capability: message.reply-preview
    @Test fun aReplyQuotesItsParentAndATapOpensTheParentWhereItIs() {
        show(message("Agreed").copy(replyTo = ReplyPreview("\$parent", ReplyPreview.State.Ready, "Sam", "Parent summary")))
        compose.onNodeWithText("Sam", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("Parent summary", useUnmergedTree = true).performClick()
        compose.runOnIdle { assertEquals("\$parent", jumped) }
    }

    // capability: message.reply-preview
    @Test fun aReplyKeepsItsHeightWhenItsParentLoads() {
        val reply = mutableStateOf(message("Agreed").copy(replyTo = ReplyPreview("\$p", ReplyPreview.State.Loading)))
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(reply.value), loading = false, hasMore = false),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        fun top() = compose.onNodeWithText("Agreed", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot.top
        val loading = top()
        compose.runOnIdle { reply.value = reply.value.copy(replyTo = ReplyPreview("\$p", ReplyPreview.State.Ready, "Sam", "Ship it?")) }
        compose.onNodeWithText("Ship it?", useUnmergedTree = true).assertExists()
        assertEquals(loading, top())
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
