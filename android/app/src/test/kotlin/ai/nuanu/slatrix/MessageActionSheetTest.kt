package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ComposerTarget
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ComposerActions
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.account.MessageActions
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.test.core.app.ApplicationProvider
import androidx.compose.ui.test.assertIsDisplayed
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class MessageActionSheetTest {
    @get:Rule val compose = createComposeRule()
    private val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
    private val theirs = message("Ship it", "Mira")
    private val mine = message("On it", "Jordan")
    private val reactions = mutableListOf<Pair<String, String>>()

    private fun show(actions: MessageActions, onOpenThread: (String) -> Unit = {}, notice: String? = null) {
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(theirs, mine), loading = false, hasMore = false, notice = notice),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {}, onOpenThread, actions = actions)
            }
        }
    }

    private fun open(body: String) = compose.onNodeWithText(body).performTouchInput { longClick() }

    // capability: message.react.quick
    @Test fun aQuickReactionReactsAtOnceAndClosesTheSheet() {
        show(MessageActions(quick = listOf("🎉", "👍"), onReact = { message, emoji -> reactions += message.body to emoji }))
        open("Ship it")
        compose.onNodeWithContentDescription("React with 👍").performClick()
        compose.runOnIdle { assertEquals(listOf("Ship it" to "👍"), reactions) }
        compose.onNodeWithContentDescription("Add reaction").assertDoesNotExist()
    }

    // capability: message.react.picker
    @Test fun addReactionFindsAnyEmojiBySlacksShortcode() {
        show(MessageActions(quick = listOf("🎉"), onReact = { message, emoji -> reactions += message.body to emoji }))
        open("Ship it")
        compose.onNodeWithContentDescription("Add reaction").performClick()
        compose.onNodeWithContentDescription("Search emoji").performTextInput("+1")
        compose.waitUntil { compose.onAllNodes(androidx.compose.ui.test.hasContentDescription("thumbs up sign")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithContentDescription("thumbs up sign").performClick()
        compose.runOnIdle { assertEquals(listOf("Ship it" to "👍"), reactions) }
    }

    // capability: message.copy-link
    // capability: message.pin
    @Test fun pinOrUnpinIsOfferedWhereYouMayPin() {
        val pins = mutableListOf<Pair<String, Boolean>>()
        show(MessageActions(pinned = setOf(mine.eventId!!), onPin = { message, pin -> pins += message.body to pin }))
        open("Ship it")
        compose.onNodeWithText("Pin to channel").performClick()
        open("On it")
        compose.onNodeWithText("Unpin from channel").performClick()
        compose.runOnIdle { assertEquals(listOf("Ship it" to true, "On it" to false), pins) }
    }

    @Test fun withoutThePowerToPinThereIsNoPin() {
        show(MessageActions())
        open("Ship it")
        compose.onNodeWithText("Copy message").assertIsDisplayed()
        compose.onNodeWithText("Pin to channel").assertDoesNotExist()
    }

    @Test fun copyLinkPutsTheMessagesLinkOnTheClipboard() {
        show(MessageActions(link = { "https://matrix.to/#/!design:example.org/${it.eventId}" }))
        open("Ship it")
        compose.onNodeWithText("Copy link to message").performClick()
        compose.waitUntil { clip() == "https://matrix.to/#/!design:example.org/\$Ship it" }
    }

    // capability: message.delete
    @Test fun deletingYourOwnMessageAsksFirst() {
        var deleted: ConversationMessage? = null
        show(MessageActions(onDelete = { deleted = it }))
        open("Ship it")
        compose.onNodeWithText("Delete message").assertDoesNotExist()
        compose.onNodeWithText("Copy message").performClick()

        open("On it")
        compose.onNodeWithText("Delete message").performClick()
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { assertNull(deleted) }
        open("On it")
        compose.onNodeWithText("Delete message").performClick()
        compose.onNodeWithText("Delete").performClick()
        compose.runOnIdle { assertEquals(mine, deleted) }
    }

    @Test fun replyOpensTheMessagesThread() {
        var thread: String? = null
        show(MessageActions(), onOpenThread = { thread = it })
        open("Ship it")
        compose.onNodeWithText("Reply").performClick()
        compose.runOnIdle { assertEquals("\$Ship it", thread) }
    }

    // capability: message.reply
    @Test fun quoteRepliesInTheComposerUnderABarThatCloses() {
        var quoted: ConversationMessage? = null
        var cancelled = false
        val composer = androidx.compose.runtime.mutableStateOf(ComposerState(loading = false))
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(theirs, mine), loading = false, hasMore = false),
                    composer.value, {}, {}, {}, {}, {}, {}, {}, {}, actions = MessageActions(onQuote = { quoted = it }),
                    composerActions = ComposerActions(onCancelTarget = { cancelled = true }))
            }
        }
        open("Ship it")
        compose.onNodeWithText("Quote").performClick()
        compose.runOnIdle {
            assertEquals(theirs, quoted)
            composer.value = ComposerState(loading = false, target = ComposerTarget.Reply("\$Ship it", "Mira", "Ship it"))
        }
        compose.onNodeWithText("Replying to Mira").assertExists()
        compose.onNodeWithContentDescription("Cancel reply").performClick()
        compose.runOnIdle { assertTrue(cancelled) }
    }

    // capability: message.edit
    @Test fun editIsOfferedOnYourOwnMessagesAndTheComposerSaysSo() {
        var editing: ConversationMessage? = null
        val composer = androidx.compose.runtime.mutableStateOf(ComposerState(loading = false))
        val editable = mine.copy(editable = true)
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(theirs.copy(editable = false), editable), loading = false, hasMore = false),
                    composer.value, {}, {}, {}, {}, {}, {}, {}, {}, actions = MessageActions(onEdit = { editing = it }))
            }
        }
        open("Ship it")
        compose.onNodeWithText("Edit message").assertDoesNotExist()
        compose.onNodeWithText("Copy message").performClick()
        open("On it")
        compose.onNodeWithText("Edit message").performClick()
        compose.runOnIdle {
            assertEquals(editable, editing)
            composer.value = ComposerState(text = "On it", loading = false, target = ComposerTarget.Edit("\$On it", "On it"))
        }
        compose.onNodeWithText("Editing message").assertExists()
        compose.onNodeWithContentDescription("Save changes").assertExists()
    }

    @Test fun aNoticeShowsWithoutOfferingRetry() {
        show(MessageActions(), notice = "Couldn’t delete this message.")
        compose.onNodeWithText("Couldn’t delete this message.").assertExists()
        compose.onNodeWithText("Retry").assertDoesNotExist()
    }

    private fun clip() = ApplicationProvider.getApplicationContext<Context>().getSystemService(ClipboardManager::class.java)
        .primaryClip?.getItemAt(0)?.text?.toString()

    private fun message(body: String, sender: String) =
        ConversationMessage(body, "\$$body", "@${sender.lowercase()}:example.org", sender, body, null, 1_700_000_000_000L,
            MessageKind.Text, MessageSendState.Sent, sender == "Jordan", sender.take(1), 0)
}
