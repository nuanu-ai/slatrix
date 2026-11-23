package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.MatrixThreadFeed
import ai.nuanu.slatrix.core.MatrixWorkspace
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.core.conversationItem
import ai.nuanu.slatrix.core.waiting
import ai.nuanu.slatrix.ui.account.ThreadsFeed
import ai.nuanu.slatrix.ui.account.ComposerActions
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assert
import androidx.compose.ui.focus.FocusManager
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertIsNotFocused
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.ComposerDraft
import org.matrix.rustcomponents.sdk.MessageContent
import org.matrix.rustcomponents.sdk.MessageType
import org.matrix.rustcomponents.sdk.MsgLikeContent
import org.matrix.rustcomponents.sdk.MsgLikeKind
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.ProfileDetails
import org.matrix.rustcomponents.sdk.Receipt
import org.matrix.rustcomponents.sdk.ReceiptThread
import org.matrix.rustcomponents.sdk.ReceiptType
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.SendQueueListener
import org.matrix.rustcomponents.sdk.TaskHandle
import org.matrix.rustcomponents.sdk.TextMessageContent
import org.matrix.rustcomponents.sdk.ThreadListEntriesListener
import org.matrix.rustcomponents.sdk.ThreadListItem
import org.matrix.rustcomponents.sdk.ThreadListItemEvent
import org.matrix.rustcomponents.sdk.ThreadListService
import org.matrix.rustcomponents.sdk.Timeline
import org.matrix.rustcomponents.sdk.TimelineConfiguration
import org.matrix.rustcomponents.sdk.TimelineDiff
import org.matrix.rustcomponents.sdk.TimelineItemContent
import org.matrix.rustcomponents.sdk.TimelineListener
import org.matrix.rustcomponents.sdk.UserReceipt
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class ThreadScreenTest {
    @get:Rule val compose = createComposeRule()

    // capability: thread.reply
    @Test fun aThreadShowsItsRootAboveItsRepliesAndRepliesFromItsOwnComposer() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        fun message(id: String, body: String, minutes: Int) = ConversationMessage(id, "\$$id", "@sam:example.org", "Sam", body,
            null, minutes * 60_000L, MessageKind.Text, MessageSendState.Sent, false, "S", 0)
        val rows = listOf(message("root", "Ship on Friday?", 0), message("a", "Yes, after QA", 1), message("b", "Agreed", 30))
        val draft = mutableStateOf(ComposerState(loading = false))
        var sent: String? = null
        var back = false
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(rows, loading = false, hasMore = false, replies = 5), draft.value,
                    { draft.value = draft.value.copy(text = it) }, { sent = draft.value.text }, { back = true },
                    {}, {}, {}, {}, {}, threadRoot = "\$root")
            }
        }

        compose.onNodeWithText("Thread").assertExists()
        compose.onNodeWithText("#design").assertExists()
        compose.onNodeWithText("5 replies").assertExists()
        compose.onNodeWithText("This is the very beginning", substring = true).assertDoesNotExist()
        val root = compose.onNodeWithText("Ship on Friday?").getUnclippedBoundsInRoot()
        val reply = compose.onNodeWithText("Yes, after QA").getUnclippedBoundsInRoot()
        assertTrue("The root tops the thread", root.bottom <= reply.top)

        compose.onNodeWithContentDescription("Add a reply").performTextReplacement("Shipping it")
        compose.onNodeWithContentDescription("Send message").performClick()
        compose.runOnIdle { assertEquals("Shipping it", sent) }
        compose.onNodeWithContentDescription("Back").performClick()
        compose.runOnIdle { assertTrue(back) }
    }

    // capability: thread.open
    @Test fun aThreadOpenedFromThreadsShowsItsRootAtOnceInTheRowItKeeps() {
        val design = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        val client = ThreadClient()
        // On the main thread, which the screen recomposes on; the conversation still maps its rows off it.
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        try {
            val threads = runBlocking { MatrixThreadFeed(scope, client, "@me:example.org", listOf(design)).state.first { !it.loading } }
            val workspace = MatrixWorkspace(scope, client)
            compose.setContent {
                SlatrixTheme {
                    val open = workspace.selected.collectAsState().value
                    if (open == null) ThreadsFeed(threads) { workspace.open(design, it) }
                    else LiveChannelScreen(open.room, open.conversation?.state?.collectAsState()?.value ?: open.waiting(),
                        ComposerState(loading = false), {}, {}, {}, { open.conversation?.loadOlder() }, {}, {}, {}, {},
                        threadRoot = open.threadRoot)
                }
            }
            // The bubble's text, apart from the row's merged semantics.
            fun bounds(text: String) = compose.onNodeWithText(text, useUnmergedTree = true).getUnclippedBoundsInRoot()

            compose.onNodeWithText("Ship on Friday?").performClick()
            compose.onNodeWithText("Thread").assertExists()
            val root = bounds("Ship on Friday?")
            compose.onNodeWithText("5 replies").assertExists()
            compose.waitUntil(5_000) { client.pageStarted.isCompleted }
            assertEquals("Held at its first page, the thread still shows its root", root, bounds("Ship on Friday?"))
            compose.onNodeWithText("5 replies").assertExists()

            client.page.complete(Unit)
            compose.waitUntil(5_000) { compose.onAllNodesWithText("Reply 1", useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
            assertEquals("The thread's own root lands in the same place", root, bounds("Ship on Friday?"))
            assertTrue("The root tops the thread", root.bottom <= bounds("Reply 1").top)
            compose.onNodeWithText("5 replies").assertExists()
        } finally {
            scope.cancel()
        }
    }

    // capability: thread.reply
    @Test fun aThreadOpenedToReplyIsReadyToTypeOnceItsDraftLoads() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        val root = ConversationMessage("root", "\$root", "@sam:example.org", "Sam", "Ship on Friday?", null, 0L, MessageKind.Text,
            MessageSendState.Sent, false, "S", 0)
        val draft = mutableStateOf(ComposerState(loading = true))
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(root), loading = false, hasMore = false), draft.value,
                    {}, {}, {}, {}, {}, {}, {}, {}, threadRoot = "\$root", replying = true)
            }
        }
        // The field can't take the keyboard until the draft is in.
        compose.waitForIdle()
        draft.value = ComposerState(loading = false)
        compose.onNode(hasContentDescription("Add a reply") and hasSetTextAction()).assertIsFocused()
    }

    // capability: thread.reply
    @Test fun aKeyboardPutAwayInAThreadOpenedToReplyStaysAwayWhenThePhoneTurns() {
        val restoration = StateRestorationTester(compose)
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        val root = ConversationMessage("root", "\$root", "@sam:example.org", "Sam", "Ship on Friday?", null, 0L, MessageKind.Text,
            MessageSendState.Sent, false, "S", 0)
        val draft = mutableStateOf(ComposerState(loading = true))
        lateinit var focus: FocusManager
        restoration.setContent {
            focus = LocalFocusManager.current
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(root), loading = false, hasMore = false), draft.value,
                    {}, {}, {}, {}, {}, {}, {}, {}, threadRoot = "\$root", replying = true)
            }
        }
        compose.waitForIdle()
        draft.value = ComposerState(loading = false)
        val field = compose.onNode(hasContentDescription("Add a reply") and hasSetTextAction())
        field.assertIsFocused()
        compose.runOnIdle { focus.clearFocus() }
        restoration.emulateSavedInstanceStateRestore()
        field.assertIsNotFocused()
    }

    // capability: thread.send-to-channel
    @Test fun theThreadComposerOffersToAlsoSendTheReplyToItsChannel() {
        val channel = RoomSummary("!ops:example.org", "ops", false, "", UnreadBadge.None, "O", 0, isPrivate = true)
        val root = ConversationMessage("root", "\$root", "@sam:example.org", "Sam", "Ship on Friday?", null, 0L, MessageKind.Text,
            MessageSendState.Sent, false, "S", 0)
        val room = mutableStateOf(channel)
        val draft = mutableStateOf(ComposerState(loading = false))
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room.value, ConversationState(listOf(root), loading = false, hasMore = false), draft.value,
                    { draft.value = draft.value.copy(text = it) }, {}, {}, {}, {}, {}, {}, {}, threadRoot = "\$root",
                    composerActions = ComposerActions(onAlsoToChannel = { draft.value = draft.value.copy(alsoToChannel = it) }))
            }
        }
        compose.onNode(hasContentDescription("Add a reply") and hasSetTextAction()).performClick()

        // Slack names the channel as its header does: a private one by its lock.
        val box = compose.onNode(isToggleable())
        box.assert(hasText("Also send to") and hasText("ops") and hasContentDescription("Private channel")).assertIsOff()
        box.performClick()
        compose.runOnIdle { assertTrue(draft.value.alsoToChannel) }
        box.assertIsOn()

        room.value = channel.copy(name = "Mira", direct = true, isPrivate = false)
        compose.onNode(isToggleable()).assert(hasText("Also send as direct message"))
    }
}

/** One room with a thread of five replies, whose timeline waits for [page]; the room's other calls answer nothing. */
private class ThreadClient : Client(NoHandle) {
    val page = CompletableDeferred<Unit>()
    val pageStarted = CompletableDeferred<Unit>()
    private val sam = "@sam:example.org"
    private val at = 1_700_000_000_000uL
    private val root = conversationItem("t-root", "\$root", "Ship on Friday?", sender = sam, timestamp = at)
    private val replies = (1..5).map { conversationItem("t-$it", "\$r$it", "Reply $it", timestamp = at + it.toULong() * 60_000uL) }

    override fun getRoom(roomId: String): Room = object : Room(NoHandle) {
        override fun id(): String = roomId
        override fun ownUserId(): String = "@me:example.org"
        override fun threadListService(): ThreadListService = object : ThreadListService(NoHandle) {
            override fun items(): List<ThreadListItem> = listOf(ThreadListItem(ThreadListItemEvent("\$root", at, sam,
                ProfileDetails.Ready("Sam Okafor", false, "mxc://example.org/sam", null, null), false,
                TimelineItemContent.MsgLike(MsgLikeContent(MsgLikeKind.Message(MessageContent(
                    MessageType.Text(TextMessageContent("Ship on Friday?", null)), "Ship on Friday?", false, null)), null, null, null))),
                null, 5u))
            override suspend fun paginate() = Unit
            override fun subscribeToItemsUpdates(listener: ThreadListEntriesListener): TaskHandle = NoTask()
        }
        override suspend fun loadUserReceipt(receiptType: ReceiptType, thread: ReceiptThread, userId: String): UserReceipt =
            UserReceipt("\$r5", Receipt(at + 300_000uL))
        override suspend fun loadComposerDraft(threadRoot: String?): ComposerDraft? = null
        override suspend fun subscribeToSendQueueUpdates(listener: SendQueueListener): TaskHandle = NoTask()
        // As the SDK does, a thread's timeline loads its first page before it opens; this one holds all five replies.
        override suspend fun timelineWithConfiguration(configuration: TimelineConfiguration): Timeline {
            pageStarted.complete(Unit)
            page.await()
            return object : Timeline(NoHandle) {
                override suspend fun addListener(listener: TimelineListener): TaskHandle {
                    listener.onUpdate(listOf(TimelineDiff.Reset(listOf(root) + replies)))
                    return NoTask()
                }
                override suspend fun paginateBackwards(numEvents: UShort): Boolean = true
            }
        }
    }

    private class NoTask : TaskHandle(NoHandle) { override fun cancel() = Unit }
}
