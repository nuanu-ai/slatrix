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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasProgressBarRangeInfo
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
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

    @Test fun olderHistoryLoadsAsTheReaderNearsTheTop() {
        val many = (1..200).map { message("Message $it", minutes = it) }
        val state = mutableStateOf(ConversationState(many, loading = false))
        var requests = 0
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, state.value, ComposerState(loading = false), {}, {}, {}, { requests++ }, {}, {})
            }
        }
        compose.onNodeWithText("Message 200").assertExists()
        compose.runOnIdle { assertEquals("The newest page is far from the top", 0, requests) }
        compose.onNodeWithText("Earlier messages").assertDoesNotExist()

        repeat(20) { compose.onRoot().performTouchInput { swipeDown() } }
        compose.waitUntil { requests == 1 }
        compose.runOnIdle { state.value = state.value.copy(loadingHistory = true) }
        compose.runOnIdle { state.value = state.value.copy(loadingHistory = false) }
        compose.waitUntil("A page that showed nothing asks again while the top is near") { requests == 2 }
    }

    @Test fun theHistoryIndicatorSitsAboveTheOldestMessageAndCoversNone() {
        val many = (1..40).map { message("Message $it", minutes = it) }
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(many, loading = false, loadingHistory = true),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {})
            }
        }
        repeat(10) { compose.onRoot().performTouchInput { swipeDown() } }
        val indicator = compose.onNode(progress).fetchSemanticsNode().boundsInRoot
        assertTrue("The indicator sits above the oldest message",
            indicator.bottom <= compose.onNodeWithText("Message 1").fetchSemanticsNode().boundsInRoot.top)
        compose.onAllNodes(hasText("Message", substring = true) or hasText("Mira")).fetchSemanticsNodes().forEach {
            assertFalse("The indicator covers a message", indicator.top < it.boundsInRoot.bottom && it.boundsInRoot.top < indicator.bottom)
        }
    }

    @Test fun theHistoryIndicatorWaitsBeforeShowing() {
        compose.mainClock.autoAdvance = false
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(message("Hello", minutes = 0)), loading = false, loadingHistory = true),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {})
            }
        }
        compose.mainClock.advanceTimeBy(200)
        compose.onNode(progress).assertDoesNotExist()
        compose.mainClock.advanceTimeBy(400)
        compose.onNode(progress).assertExists()
    }

    @Test fun theStartOfAChannelOrDirectMessageShowsItsIntro() {
        val state = mutableStateOf(ConversationState(listOf(message("Hello", minutes = 0)), loading = false))
        val current = mutableStateOf(room)
        compose.setContent {
            SlatrixTheme { LiveChannelScreen(current.value, state.value, ComposerState(loading = false), {}, {}, {}, {}, {}, {}) }
        }
        compose.onNodeWithText("Hello").assertIsDisplayed()
        compose.onNodeWithText("This is the very beginning of the #design channel.").assertDoesNotExist()

        compose.runOnIdle { state.value = state.value.copy(hasMore = false) }
        compose.onNodeWithText("This is the very beginning of the #design channel.").assertIsDisplayed()
        compose.runOnIdle { current.value = RoomSummary("!mira:example.org", "Mira Chen", true, "", UnreadBadge.None, "MC", 2) }
        compose.onNodeWithText("This conversation is just between Mira Chen and you.").assertIsDisplayed()
    }

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
                    {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNodeWithText("Today").assertIsDisplayed()
        compose.onNodeWithText("Yesterday").assertIsDisplayed()
        compose.onNodeWithText("Oct 23rd, 2023").assertIsDisplayed()
    }

    @Test fun aGroupedMessageDropsAvatarAndNameAndKeepsItsTimeInItsMenu() {
        val at = LocalDate.now().atTime(9, 41).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val rows = listOf(message("First", minutes = 0).copy(timestamp = at), message("Second", minutes = 0).copy(timestamp = at, grouped = true))
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(rows, loading = false, hasMore = false), ComposerState(loading = false),
                    {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNodeWithText("Second").assertIsDisplayed()
        compose.onAllNodesWithText("Mira", useUnmergedTree = true).assertCountEquals(1)
        compose.onAllNodesWithText("M", useUnmergedTree = true).assertCountEquals(1)
        compose.onNodeWithText("Second").performTouchInput { longClick() }
        compose.onNodeWithText("9:41", substring = true).assertIsDisplayed()
    }

    private val progress = hasProgressBarRangeInfo(ProgressBarRangeInfo.Indeterminate)

    private fun message(body: String, minutes: Int, sender: String = "Mira", state: MessageSendState = MessageSendState.Sent) =
        ConversationMessage(body, "\$$body", "@${sender.lowercase()}:example.org", sender, body, null,
            1_700_000_000_000L + minutes * 600_000L, MessageKind.Text, state, sender == "Jordan", sender.take(1), 0)
}
