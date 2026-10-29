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
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import android.app.Application
import android.content.ClipboardManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.compose.ui.test.performClick
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.hasProgressBarRangeInfo
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeUp
import java.time.LocalDate
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class LiveChannelScreenTest {
    @get:Rule val compose = createComposeRule()
    private val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)

    // capability: conversation.history
    @Test fun olderHistoryLoadsAsTheReaderNearsTheTop() {
        val many = (1..200).map { message("Message $it", minutes = it) }
        val state = mutableStateOf(ConversationState())
        var requests = 0
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, state.value, ComposerState(loading = false), {}, {}, {}, { requests++ }, {}, {}, {}, {})
            }
        }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals("Nothing pages before the cached messages land", 0, requests) }
        compose.runOnIdle { state.value = ConversationState(many, loading = false) }
        compose.onNodeWithText("Message 200").assertExists()
        compose.runOnIdle { assertEquals("The newest page is far from the top", 0, requests) }
        compose.onNodeWithText("Earlier messages").assertDoesNotExist()

        repeat(20) { compose.onNode(hasScrollToIndexAction()).performTouchInput { swipeDown() } }
        compose.waitUntil { requests == 1 }
        compose.runOnIdle { state.value = state.value.copy(loadingHistory = true) }
        compose.waitForIdle()
        compose.runOnIdle { state.value = state.value.copy(loadingHistory = false) }
        compose.waitForIdle()
        compose.waitUntil("A page that showed nothing asks again while the top is near") { requests == 2 }
    }

    @Test fun aFailedPageWaitsForRetryInsteadOfAskingAgain() {
        var requests = 0
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(message("Hello", minutes = 0)), loading = false,
                    error = "Couldn’t load older messages."), ComposerState(loading = false), {}, {}, {}, { requests++ }, {}, {}, {}, {})
            }
        }
        compose.onNodeWithText("Couldn’t load older messages.").assertIsDisplayed()
        compose.runOnIdle { assertEquals(0, requests) }
    }

    @Test fun theHistoryIndicatorSitsAboveTheOldestMessageAndCoversNone() {
        val many = (1..40).map { message("Message $it", minutes = it) }
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(many, loading = false, loadingHistory = true),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        repeat(10) { compose.onNode(hasScrollToIndexAction()).performTouchInput { swipeDown() } }
        val indicator = compose.onNode(progress).fetchSemanticsNode().boundsInRoot
        assertTrue("The indicator sits above the oldest message",
            indicator.bottom <= compose.onNodeWithText("Message 1").fetchSemanticsNode().boundsInRoot.top)
        compose.onAllNodes(hasText("Message", substring = true) or hasText("Mira")).fetchSemanticsNodes().forEach {
            assertFalse("The indicator covers a message", indicator.top < it.boundsInRoot.bottom && it.boundsInRoot.top < indicator.bottom)
        }
    }

    @Test fun theHistoryIndicatorWaitsBeforeShowingAndStaysAcrossBackToBackPages() {
        val state = mutableStateOf(ConversationState(listOf(message("Hello", minutes = 0)), loading = false, loadingHistory = true))
        compose.mainClock.autoAdvance = false
        compose.setContent {
            SlatrixTheme { LiveChannelScreen(room, state.value, ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {}) }
        }
        compose.mainClock.advanceTimeBy(200)
        compose.onNode(progress).assertDoesNotExist()
        compose.mainClock.advanceTimeBy(400)
        compose.onNode(progress).assertExists()

        compose.runOnIdle { state.value = state.value.copy(loadingHistory = false) }
        compose.mainClock.advanceTimeBy(100)
        compose.runOnIdle { state.value = state.value.copy(loadingHistory = true) }
        compose.mainClock.advanceTimeBy(100)
        compose.onNode(progress).assertExists()
    }

    // capability: conversation.intro
    @Test fun theStartOfAChannelOrDirectMessageShowsItsIntro() {
        val state = mutableStateOf(ConversationState(listOf(message("Hello", minutes = 0)), loading = false))
        val current = mutableStateOf(room)
        compose.setContent {
            SlatrixTheme { LiveChannelScreen(current.value, state.value, ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {}) }
        }
        compose.onNodeWithText("Hello").assertIsDisplayed()
        compose.onNodeWithText("This is the very beginning of the #design channel.").assertDoesNotExist()

        compose.runOnIdle { state.value = state.value.copy(hasMore = false) }
        compose.onNodeWithText("This is the very beginning of the #design channel.").assertIsDisplayed()
        compose.runOnIdle { current.value = RoomSummary("!mira:example.org", "Mira Chen", true, "", UnreadBadge.None, "MC", 2) }
        compose.onNodeWithText("This conversation is just between Mira Chen and you.").assertIsDisplayed()
    }

    // capability: conversation.day-dividers
    @Test fun dayDividersReadTodayYesterdayOrTheDate() {
        fun noon(day: LocalDate) = day.atTime(12, 0).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val today = LocalDate.now()
        val rows = listOf(
            DayDivider("older", noon(LocalDate.of(2023, 10, 23))), message("Back then", minutes = 0),
            DayDivider("yesterday", noon(today.minusDays(1))), message("Yesterday's", minutes = 1),
            DayDivider("today", noon(today)), message("Today's", minutes = 2),
        )
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(rows, loading = false, hasMore = false), ComposerState(loading = false),
                    {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNodeWithText("Today").assertIsDisplayed()
        compose.onNodeWithText("Yesterday").assertIsDisplayed()
        compose.onNodeWithText("Oct 23rd, 2023").assertIsDisplayed()
    }

    // capability: conversation.grouping
    @Test fun aGroupedMessageDropsAvatarAndNameAndKeepsItsTimeInItsMenu() {
        val at = LocalDate.now().atTime(9, 41).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val rows = listOf(message("First", minutes = 0).copy(timestamp = at), message("Second", minutes = 0).copy(timestamp = at, grouped = true))
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(rows, loading = false, hasMore = false), ComposerState(loading = false),
                    {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNodeWithText("Second").assertIsDisplayed()
        compose.onAllNodesWithText("Mira", useUnmergedTree = true).assertCountEquals(1)
        compose.onAllNodesWithText("M", useUnmergedTree = true).assertCountEquals(1)
        compose.onNodeWithText("Second").performTouchInput { longClick() }
        compose.onNodeWithText("Today at 9:41", substring = true).assertIsDisplayed()
    }

    // capability: message.retry-failed
    // capability: message.copy-text
    @Test fun theMessageSheetCopiesTextAndRetriesOrDeletesAFailedMessage() {
        val failed = message("Lost on the way", minutes = 1, sender = "Jordan", state = MessageSendState.Failed)
            .copy(transactionId = "txn", canRetry = true)
        var retried: ConversationMessage? = null
        var deleted: ConversationMessage? = null
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(message("Ship it", minutes = 0), failed), loading = false, hasMore = false),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, onRetrySend = { retried = it }, onDeleteUnsent = { deleted = it })
            }
        }
        compose.onNodeWithText("Ship it")
            .assert(SemanticsMatcher.keyNotDefined(SemanticsActions.OnClick).and(SemanticsMatcher.keyIsDefined(SemanticsActions.OnLongClick)))
            .performTouchInput { longClick() }
        compose.onNodeWithText("Retry").assertDoesNotExist()
        compose.onNodeWithText("Copy message").performClick()
        compose.waitUntil { clipboard.primaryClip?.getItemAt(0)?.text?.toString() == "Ship it" }
        compose.onNodeWithText("Copy message").assertDoesNotExist()

        compose.onNodeWithText("Lost on the way").performClick()
        compose.onNodeWithText("Retry").performClick()
        compose.runOnIdle { assertEquals(failed, retried) }
        compose.onNodeWithText("Lost on the way").performTouchInput { longClick() }
        compose.onNodeWithText("Delete message").performClick()
        compose.runOnIdle { assertEquals(failed, deleted) }
    }

    @Test fun theHeaderNamesTheChannelInPrimaryTextAndSendEndsTheComposerToolbar() {
        compose.setContent {
            SlatrixTheme(dark = false) {
                LiveChannelScreen(room.copy(topic = "Launch reviews"), ConversationState(loading = false, hasMore = false),
                    ComposerState(text = "Draft", loading = false), {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNodeWithText("design", useUnmergedTree = true).performSemanticsAction(SemanticsActions.GetTextLayoutResult) { action ->
            val layouts = mutableListOf<TextLayoutResult>()
            action(layouts)
            assertEquals(DesignTokens.colors(false, SidebarPalette.Aubergine).getValue("textPrimary"), layouts.single().layoutInput.style.color)
        }
        compose.onNodeWithContentDescription("Message #design").performClick()
        val field = compose.onNodeWithContentDescription("Message #design").fetchSemanticsNode().boundsInRoot
        val send = compose.onNodeWithContentDescription("Send message").fetchSemanticsNode().boundsInRoot
        val mention = compose.onNodeWithContentDescription("Mention someone").fetchSemanticsNode().boundsInRoot
        assertTrue("Send ends the toolbar row under the field, as in Slack",
            send.top >= field.bottom && send.center.y in mention.top..mention.bottom && send.left > mention.right)
    }

    // capability: channel.read-only
    @Test fun aChannelYouCantPostInSaysSoInPlaceOfTheComposerAndItsThreadsDoToo() {
        val threadRoot = mutableStateOf<String?>(null)
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room.copy(canPost = false), ConversationState(listOf(message("Welcome", minutes = 1)),
                    loading = false, hasMore = false), ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                    threadRoot = threadRoot.value)
            }
        }
        compose.onNodeWithText("Welcome").assertIsDisplayed()
        compose.onNodeWithText("You don’t have permission to post in this channel.").assertIsDisplayed()
        compose.onNodeWithContentDescription("Message #design").assertDoesNotExist()

        compose.runOnIdle { threadRoot.value = "\$Welcome" }
        compose.onNodeWithText("You don’t have permission to post in this channel.").assertIsDisplayed()
        compose.onNodeWithContentDescription("Add a reply").assertDoesNotExist()
    }

    @Test fun theMemberLineHoldsItsPlaceUntilTheCountArrivesAndADirectMessageHasNone() {
        val shown = mutableStateOf(room.copy(topic = "Launch reviews"))
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(shown.value, ConversationState(loading = false, hasMore = false), ComposerState(loading = false),
                    {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        val waiting = compose.onNodeWithText("design").fetchSemanticsNode().boundsInRoot
        compose.runOnIdle { shown.value = shown.value.copy(memberCount = 1) }
        compose.onNodeWithText("1 member").assertIsDisplayed()
        assertEquals("Nothing moves when the count arrives", waiting, compose.onNodeWithText("design").fetchSemanticsNode().boundsInRoot)

        compose.runOnIdle { shown.value = RoomSummary("!sam:example.org", "Sam", true, "", UnreadBadge.None, "S", 0, memberCount = 2) }
        compose.waitForIdle()
        compose.onNodeWithText("2 members").assertDoesNotExist()
    }

    private val clipboard get() = ApplicationProvider.getApplicationContext<Context>().getSystemService(ClipboardManager::class.java)

    private val progress = hasProgressBarRangeInfo(ProgressBarRangeInfo.Indeterminate)

    // capability: conversation.jump-to-message
    @Test fun aJumpShowsItsMessageAndAsksForNewerOnceTheNewestShows() {
        val many = (1..200).map { message("Message $it", minutes = it) }
        val state = mutableStateOf(ConversationState(many, loading = false, highlight = "\$Message 20", focused = true))
        var newer = 0
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, state.value, ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                    onLoadNewer = { newer++ })
            }
        }
        compose.onNodeWithText("Message 20").assertIsDisplayed()
        compose.onNodeWithText("Message 200").assertDoesNotExist()
        compose.runOnIdle { assertEquals("Newer messages wait until the reader reaches the newest", 0, newer) }

        // On the conversation itself: a swipe that starts on the composer doesn't scroll it.
        repeat(30) { compose.onNode(hasScrollToIndexAction()).performTouchInput { swipeUp() } }
        compose.waitUntil { newer > 0 }
    }

    // capability: conversation.unread-line
    @Test fun anUnreadConversationOpensWithItsNewLineAtTheTopAndKeepsItOnceRead() {
        val many = (1..200).map { message("Message $it", minutes = it) }
        val state = mutableStateOf(ConversationState(many, loading = false, firstUnread = "\$Message 185", startsAtUnread = true))
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, state.value, ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNodeWithText("New").assertIsDisplayed()
        compose.onNodeWithText("Message 185").assertIsDisplayed()
        compose.onNodeWithText("Message 184").assertIsNotDisplayed()
        compose.onNodeWithText("Message 200").assertIsNotDisplayed()

        // Reading moves the SDK's marker after the newest message; the line stays until the reader leaves.
        compose.runOnIdle { state.value = state.value.copy(firstUnread = null) }
        compose.onNodeWithText("New").assertIsDisplayed()
    }

    @Test fun aConversationWithNothingToResumeOpensAtItsNewestEvenWithAReadMarkerBehind() {
        // The fully-read marker can trail the read receipt, so the SDK's marker alone doesn't make a conversation unread.
        val many = (1..200).map { message("Message $it", minutes = it) }
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(many, loading = false, firstUnread = "\$Message 185"),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNodeWithText("Message 200").assertIsDisplayed()
    }

    // capability: composer.typing
    @Test fun whoIsTypingShowsOverTheConversationsEndWithoutMovingIt() {
        val typing = mutableStateOf(emptyList<String>())
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(message("Hello", minutes = 0)), loading = false, hasMore = false),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {}, typing = typing.value)
            }
        }
        val before = compose.onNodeWithText("Hello").fetchSemanticsNode().boundsInRoot
        compose.runOnIdle { typing.value = listOf("Sam") }
        compose.onNodeWithText("Sam is typing…").assertIsDisplayed()
        assertEquals(before, compose.onNodeWithText("Hello").fetchSemanticsNode().boundsInRoot)
        compose.runOnIdle { typing.value = listOf("Sam", "Mira") }
        compose.onNodeWithText("Sam and Mira are typing…").assertIsDisplayed()
        compose.runOnIdle { typing.value = listOf("Sam", "Mira", "Quinn") }
        compose.onNodeWithText("Several people are typing…").assertIsDisplayed()
        compose.runOnIdle { typing.value = emptyList() }
        compose.onNodeWithText("typing", substring = true).assertDoesNotExist()
    }

    private fun message(body: String, minutes: Int, sender: String = "Mira", state: MessageSendState = MessageSendState.Sent) =
        ConversationMessage(body, "\$$body", "@${sender.lowercase()}:example.org", sender, body, null,
            1_700_000_000_000L + minutes * 600_000L, MessageKind.Text, state, sender == "Jordan", sender.take(1), 0)
}
