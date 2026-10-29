package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.MessageSearchState
import ai.nuanu.slatrix.core.PeopleSearchState
import ai.nuanu.slatrix.core.Person
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.NewMessageScreen
import ai.nuanu.slatrix.ui.account.SearchScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Starting a conversation with someone: Home's +, the New message page, and people in Search. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class NewMessageScreenTest {
    @get:Rule val compose = createComposeRule()
    private val wanda = RoomSummary("!wm:example.org", "Wanda Moss", true, "", UnreadBadge.None, "WM", 1)
    private val sam = Person("@sam:example.org", "Sam Lee")

    // capability: people.start-dm
    @Test fun homesPlusStartsANewMessageOnHomeAndDms() {
        var started = 0
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(listOf(wanda), loading = false, spacesKnown = true), {}, {}, {},
                    onNewMessage = { started++ })
            }
        }
        compose.onNodeWithContentDescription("New message").performClick()
        compose.onNode(hasText("DMs") and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected)).performClick()
        compose.onNodeWithContentDescription("New message").performClick()
        compose.runOnIdle { assertEquals(2, started) }
    }

    @Test fun thePlusNeverCoversTheLastConversation() {
        val many = (1..30).map { RoomSummary("!dm$it:example.org", "Person $it", true, "", UnreadBadge.None, "P", 0) }
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(many, loading = false, spacesKnown = true), {}, {}, {}, onNewMessage = {})
            }
        }
        compose.onNode(hasText("DMs") and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected)).performClick()
        repeat(10) { compose.onNode(hasScrollAction()).performTouchInput { swipeUp() } }
        val last = compose.onNodeWithText("Person 30").fetchSemanticsNode().boundsInRoot
        val plus = compose.onNodeWithContentDescription("New message").fetchSemanticsNode().boundsInRoot
        assertTrue("The last row ends above the +", last.bottom <= plus.top)
    }

    // capability: people.start-dm
    // capability: search.people
    @Test fun aNewMessageFindsPeopleInTheDirectoryAndOpensTheirConversation() {
        val queries = mutableListOf<String>()
        val picked = mutableListOf<Person>()
        val rooms = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                NewMessageScreen(PeopleSearchState("sam", listOf(sam)), listOf(wanda), opening = null, error = null,
                    onQuery = { queries += it }, onPerson = { picked += it }, onRoom = { rooms += it }, onBack = {})
            }
        }
        compose.onNodeWithText("Wanda Moss").performClick()
        compose.onNode(hasSetTextAction()).performTextInput("sam")
        compose.onNodeWithText("@sam:example.org").assertIsDisplayed()
        compose.onNodeWithText("Sam Lee").performClick()
        compose.runOnIdle {
            assertEquals(listOf(wanda.id), rooms)
            assertEquals("sam", queries.last())
            assertEquals(listOf(sam), picked)
        }
    }

    // capability: search.people
    @Test fun searchFindsPeopleBeyondYourConversations() {
        val opened = mutableListOf<Person>()
        val asked = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                SearchScreen(listOf(wanda), "@alex:example.org", MessageSearchState(), {}, {}, {}, people = PeopleSearchState("sa", listOf(sam)),
                    onPeopleQuery = { asked += it }, onPerson = { opened += it }, onRoom = {})
            }
        }
        compose.onNode(hasSetTextAction()).performTextInput("sa")
        compose.onNodeWithText("Sam Lee", substring = true).performClick()
        compose.runOnIdle {
            assertEquals("sa", asked.last())
            assertEquals(listOf(sam), opened)
        }
    }
}
