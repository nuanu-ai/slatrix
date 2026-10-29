package ai.nuanu.slatrix

import android.app.Application
import android.view.WindowInsetsController
import ai.nuanu.slatrix.core.LatestMessage
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SpaceSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.LiveWorkspace
import ai.nuanu.slatrix.ui.account.LiveYouScreen
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.ComponentActivity
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performTextReplacement
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
class LiveHomeScreenTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun backFromAConversationRestoresTheTabSearchAndScrollPosition() {
        val people = (0 until 40).map { direct("!p$it:example.org", "Person $it", latest = LatestMessage("Hello $it", 1_000L - it, false)) }
        val open = mutableStateOf(false)
        compose.setContent {
            SlatrixTheme {
                LiveWorkspace(if (open.value) { { Text("Conversation") } } else null) {
                    LiveHomeScreen("@alex:example.org", RoomListState(people, loading = false, spacesKnown = true), { open.value = true }, {}, {})
                }
            }
        }
        tab("DMs").performClick()
        compose.onNode(hasSetTextAction()).performTextReplacement("Person")
        compose.onNode(hasScrollToIndexAction()).performScrollToIndex(40)
        compose.onNodeWithText("Person 39").performClick()
        compose.onNodeWithText("Conversation").assertExists()

        compose.runOnIdle { open.value = false }
        tab("DMs").assertIsSelected()
        compose.onNodeWithText("Person 39").assertIsDisplayed()
        compose.onNode(hasScrollToIndexAction()).performScrollToIndex(0)
        compose.onNode(hasSetTextAction()).assertTextContains("Person")
    }

    @Test fun theDmsTabListsTheNewestConversationFirstWithItsLatestMessage() {
        val rooms = listOf(
            direct("!blake:example.org", "Blake", latest = LatestMessage("Shipped it", 2_000, own = true)),
            direct("!avery:example.org", "Avery", latest = LatestMessage("See you at noon", 1_000, own = false)),
        )
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {}) } }
        tab("DMs").performClick()

        compose.onNodeWithText("You: Shipped it").assertIsDisplayed()
        compose.onNodeWithText("See you at noon").assertIsDisplayed()
        val blake = compose.onNodeWithText("Blake").fetchSemanticsNode().boundsInRoot
        val avery = compose.onNodeWithText("Avery").fetchSemanticsNode().boundsInRoot
        assertTrue("The newest conversation leads", blake.top < avery.top)
    }

    @Test fun directMessageNamesLineUpWhateverTheirInitials() {
        val rooms = listOf(direct("!wm:example.org", "Wanda Moss"), direct("!n:example.org", "Nina"))
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {}) } }

        val twoLetters = compose.onNodeWithText("Wanda Moss", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot.left
        val oneLetter = compose.onNodeWithText("Nina", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot.left
        assertEquals(oneLetter, twoLetters, 0.5f)
    }

    @Test fun unreadRoomsAnnounceWhatTheirBadgeCounts() {
        val rooms = listOf(
            RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.Count("3"), "T", 0),
            direct("!sam:example.org", "Sam", unread = UnreadBadge.Bold),
        )
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {}) } }

        compose.onNodeWithText("Team").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "3 mentions"))
        compose.onNodeWithText("Sam").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Unread"))
    }

    @Test fun theHeaderAvatarOpensYouAndOnlyHomeAndDmsAreTabs() {
        var openedYou = false
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", RoomListState(loading = false, spacesKnown = true), {}, { openedYou = true }, {}) } }
        tab("Home").assertIsSelected()
        tab("DMs").assertIsDisplayed()
        tab("You").assertDoesNotExist()

        compose.onNodeWithContentDescription("You").performClick()
        compose.runOnIdle { assertTrue(openedYou) }
    }

    @Test fun youIsAPageWithPreferencesSignOutAndBack() {
        var preferences = false
        var signedOut = false
        var back = false
        compose.setContent {
            SlatrixTheme { LiveYouScreen("@alex:example.org", { preferences = true }, { signedOut = true }, { back = true }) }
        }
        compose.onNodeWithText("@alex:example.org").assertIsDisplayed()
        compose.onNodeWithText("Preferences").performClick()
        compose.runOnIdle { assertTrue(preferences) }

        compose.onNodeWithText("Sign out").performClick()
        compose.runOnIdle { assertFalse(signedOut) }
        compose.onNode(hasText("Sign out") and hasAnyAncestor(isDialog()) and hasClickAction()).performClick()
        compose.runOnIdle { assertTrue(signedOut) }

        compose.onNodeWithContentDescription("Back").performClick()
        compose.runOnIdle { assertTrue(back) }
    }

    @Test fun aSavedWorkspaceShowsItsChannelsAndDirectMessagesTogether() {
        val channel = RoomSummary("!work:example.org", "Work channel", false, "", UnreadBadge.None, "W", 0)
        val sam = direct("!sam:example.org", "Sam")
        val state = mutableStateOf(RoomListState(listOf(channel, sam), loading = false, spaces = listOf(SpaceSummary("!nuanu:example.org", "Nuanu"))))
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", state.value, {}, {}, {}, "!nuanu:example.org") } }
        compose.onNodeWithText("Sam").assertDoesNotExist()

        compose.runOnIdle {
            state.value = state.value.copy(rooms = listOf(channel.copy(spaceIds = setOf("!nuanu:example.org")), sam), spacesKnown = true)
        }
        compose.onNodeWithText("Work channel").assertIsDisplayed()
        compose.onNodeWithText("Sam").assertIsDisplayed()
    }

    @Test fun theWorkspaceHeaderSitsOnTheWorkspaceColorInLightMode() {
        compose.setContent { SlatrixTheme(dark = false) { LiveHomeScreen("@alex:example.org", RoomListState(loading = false, spacesKnown = true), {}, {}, {}) } }

        val header = compose.onNodeWithContentDescription("Switch workspace").fetchSemanticsNode().boundsInWindow
        compose.runOnIdle {
            val window = compose.activity.window.decorView
            val bitmap = Bitmap.createBitmap(window.width, window.height, Bitmap.Config.ARGB_8888)
            window.draw(Canvas(bitmap))
            val pixel = Color(bitmap.getPixel(header.right.toInt() - 1, header.top.toInt()))
            assertEquals(DesignTokens.colors(true, SidebarPalette.Aubergine).getValue("frame"), pixel)
        }
        compose.runOnIdle {
            val appearance = compose.activity.window.insetsController!!.systemBarsAppearance
            assertEquals("Status bar icons must be light over the workspace color", 0, appearance and WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS)
        }
    }

    private fun tab(label: String) =
        compose.onNode(hasText(label) and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected))

    private fun direct(id: String, name: String, unread: UnreadBadge = UnreadBadge.None, latest: LatestMessage? = null) =
        RoomSummary(id, name, true, "", unread, name.split(" ").joinToString("") { it.take(1) }, 0, latest = latest)
}
