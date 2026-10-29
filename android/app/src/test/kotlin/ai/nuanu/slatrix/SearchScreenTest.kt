package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.MessageSearchQuery
import ai.nuanu.slatrix.core.MessageSearchState
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SearchHit
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.SearchScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performTextInput
import org.junit.Assert.assertEquals
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
class SearchScreenTest {
    @get:Rule val compose = createComposeRule()

    private val rooms = listOf(
        channel("!product:example.org", "Product design"),
        channel("!design:example.org", "design"),
        channel("!general:example.org", "general"),
        RoomSummary("!desmond:example.org", "Desmond Fry", true, "", UnreadBadge.None, "DF", 1),
    )

    @Test fun openingSearchPutsTheCursorInTheField() {
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {},
                    search = { SearchScreen(rooms, "@alex:example.org", MessageSearchState(), {}, {}, {}, onRoom = {}) })
            }
        }
        compose.onNode(hasText("Search") and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected)).performClick()
        compose.onNode(hasSetTextAction()).assertIsFocused()
    }

    // capability: search.rooms
    // capability: search.people
    @Test fun typingFindsChannelsAndPeopleBestMatchFirst() {
        val opened = mutableListOf<String>()
        compose.setContent { SlatrixTheme { SearchScreen(rooms, "@alex:example.org", MessageSearchState(), {}, {}, {}) { opened += it } } }
        compose.onNode(hasSetTextAction()).performTextInput("des")

        assertTrue("A name that starts with the query leads", top("design") < top("Product design"))
        assertTrue(top("Channels") < top("design") && top("People") < top("Desmond Fry"))
        compose.onNodeWithText("general").assertDoesNotExist()
        compose.onNodeWithText("Desmond Fry").performClick()
        compose.runOnIdle { assertEquals(listOf("!desmond:example.org"), opened) }
    }

    // capability: search.messages
    @Test fun searchingMessagesShowsEachHitWithItsConversationAndOpensItWhereItIs() {
        val asked = mutableListOf<MessageSearchQuery?>()
        val jumped = mutableListOf<SearchHit>()
        val messages = mutableStateOf(MessageSearchState())
        compose.setContent {
            SlatrixTheme { SearchScreen(rooms, "@alex:example.org", messages.value, { asked += it }, {}, { jumped += it }) {} }
        }
        compose.onNode(hasSetTextAction()).performTextInput("budget in:#design")
        compose.onNode(hasSetTextAction()).performImeAction()
        compose.runOnIdle { assertEquals(MessageSearchQuery("budget", roomId = "!design:example.org"), asked.last()) }

        compose.runOnIdle {
            messages.value = MessageSearchState(asked.last(), listOf(SearchHit("!design:example.org", "\$1", "@sam:example.org", "Sam",
                "The budget is ready for review", 1_000)))
        }
        compose.onNodeWithText("The budget is ready for review").assertIsDisplayed()
        compose.onNodeWithText("Sam").assertIsDisplayed()
        compose.onNodeWithText("#design").assertIsDisplayed()
        compose.onNodeWithText("The budget is ready for review").performClick()
        compose.runOnIdle { assertEquals(listOf("!design:example.org" to "\$1"), jumped.map { it.roomId to it.eventId }) }
    }

    @Test fun aSearchWhosePageHasNoHitsHereAsksForTheNextInsteadOfSayingNoResults() {
        var more = 0
        val elsewhere = SearchHit("!elsewhere:example.org", "\$1", "@sam:example.org", "Sam", "budget elsewhere", 1_000)
        compose.setContent {
            SlatrixTheme {
                SearchScreen(rooms, "@alex:example.org", MessageSearchState(MessageSearchQuery("budget"), listOf(elsewhere), endReached = false),
                    {}, { more++ }, {}, onRoom = {})
            }
        }
        compose.onNode(hasSetTextAction()).performTextInput("budget")
        compose.onNode(hasSetTextAction()).performImeAction()
        compose.runOnIdle { assertTrue("The next page is asked for", more > 0) }
        compose.onNodeWithText("No results for “budget”").assertDoesNotExist()
    }

    @Test fun aSearchWithNoHitsSaysSo() {
        compose.setContent {
            SlatrixTheme { SearchScreen(rooms, "@alex:example.org", MessageSearchState(MessageSearchQuery("zebra")), {}, {}, {}, onRoom = {}) }
        }
        compose.onNode(hasSetTextAction()).performTextInput("zebra")
        compose.onNode(hasSetTextAction()).performImeAction()
        compose.onNodeWithText("No results for “zebra”").assertIsDisplayed()
    }

    // capability: search.recent
    @Test fun anEmptyFieldOffersRecentSearchesAndOneSearchesAgain() {
        val asked = mutableListOf<MessageSearchQuery?>()
        val searched = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                SearchScreen(rooms, "@alex:example.org", MessageSearchState(), { asked += it }, {}, {},
                    listOf("budget in:#design", "launch"), { searched += it }) {}
            }
        }
        compose.onNodeWithText("Recent searches").assertIsDisplayed()
        compose.onNodeWithText("budget in:#design").performClick()

        compose.runOnIdle {
            assertEquals(MessageSearchQuery("budget", roomId = "!design:example.org"), asked.last())
            assertEquals(listOf("budget in:#design"), searched)
        }
        compose.onNode(hasSetTextAction()).assert(hasText("budget in:#design"))
    }

    // capability: search.recent
    @Test fun aSearchIsRememberedAndTypingOffersTheRecentOnesThatMatch() {
        val searched = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme { SearchScreen(rooms, "@alex:example.org", MessageSearchState(), {}, {}, {}, listOf("launch plan", "budget"), { searched += it }) {} }
        }
        compose.onNode(hasSetTextAction()).performTextInput("lau")
        compose.onNodeWithText("launch plan").assertIsDisplayed()
        compose.onNodeWithText("budget").assertDoesNotExist()

        compose.onNode(hasSetTextAction()).performImeAction()
        compose.runOnIdle { assertEquals(listOf("lau"), searched) }
    }

    private fun top(text: String) = compose.onNodeWithText(text).fetchSemanticsNode().boundsInRoot.top

    private fun channel(id: String, name: String) = RoomSummary(id, name, false, "", UnreadBadge.None, name.take(1), 0)
}
