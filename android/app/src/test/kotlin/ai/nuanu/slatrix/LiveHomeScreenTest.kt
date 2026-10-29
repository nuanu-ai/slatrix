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
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performTouchInput
import kotlinx.coroutines.CompletableDeferred
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

    @Test fun backFromAConversationRestoresTheTabAndScrollPosition() {
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
        compose.onNode(hasScrollToIndexAction()).performScrollToIndex(39)
        compose.onNodeWithText("Person 39").performClick()
        compose.onNodeWithText("Conversation").assertExists()

        compose.runOnIdle { open.value = false }
        tab("DMs").assertIsSelected()
        compose.onNodeWithText("Person 39").assertIsDisplayed()
    }

    @Test fun homeAndDmsListConversationsWithoutAPermanentSearchField() {
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", RoomListState(listOf(direct("!sam:example.org", "Sam")), loading = false, spacesKnown = true), {}, {}, {}) } }
        compose.onNode(hasSetTextAction()).assertDoesNotExist()
        tab("DMs").performClick()
        compose.onNode(hasSetTextAction()).assertDoesNotExist()
    }

    // capability: home.starred
    @Test fun starredConversationsLeadInTheirOwnSection() {
        val rooms = listOf(
            channel("!general:example.org", "general"),
            channel("!design:example.org", "design").copy(starred = true),
            direct("!sam:example.org", "Sam").copy(starred = true),
            direct("!avery:example.org", "Avery"),
        )
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {}) } }

        val starred = top("Starred")
        val channels = top("Channels")
        val direct = top("Direct messages")
        assertTrue(starred < top("design") && top("design") < channels)
        assertTrue(starred < top("Sam") && top("Sam") < channels)
        assertTrue(channels < top("general") && top("general") < direct)
        assertTrue(direct < top("Avery"))
        compose.onAllNodesWithText("design").assertCountEquals(1)
        compose.onAllNodesWithText("Sam").assertCountEquals(1)
    }

    @Test fun withNothingStarredThereIsNoStarredSection() {
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", RoomListState(listOf(channel("!general:example.org", "general")), loading = false, spacesKnown = true), {}, {}, {}) } }
        compose.onNodeWithText("Channels").assertIsDisplayed()
        compose.onNodeWithText("Starred").assertDoesNotExist()
    }

    // capability: home.sections-collapse
    @Test fun aSectionHeaderCollapsesAndExpandsItsConversations() {
        val rooms = listOf(channel("!general:example.org", "general"), direct("!sam:example.org", "Sam"))
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {}) } }

        compose.onNodeWithText("Channels").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Expanded"))
        compose.onNodeWithText("Channels").performClick()
        compose.onNodeWithText("general").assertDoesNotExist()
        compose.onNodeWithText("Sam").assertIsDisplayed()
        compose.onNodeWithText("Channels").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Collapsed"))

        compose.onNodeWithText("Channels").performClick()
        compose.onNodeWithText("general").assertIsDisplayed()
    }

    // capability: home.private-channel-icon
    @Test fun privateChannelsShowALock() {
        val rooms = listOf(channel("!secret:example.org", "secret").copy(isPrivate = true), channel("!general:example.org", "general"))
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {}) } }

        compose.onNode(hasText("secret") and hasContentDescription("Private channel")).assertIsDisplayed()
        compose.onNode(hasText("general") and hasContentDescription("Private channel")).assertDoesNotExist()
    }

    // capability: home.star-toggle
    @Test fun longPressingAConversationStarsOrUnstarsIt() {
        val starred = mutableListOf<Pair<String, Boolean>>()
        val rooms = listOf(channel("!general:example.org", "general"), direct("!sam:example.org", "Sam").copy(starred = true))
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {},
                    onStar = { id, star -> starred += id to star; true })
            }
        }
        compose.onNodeWithText("general").performTouchInput { longClick() }
        compose.onNodeWithText("Star channel").performClick()
        compose.onNodeWithText("Sam").performTouchInput { longClick() }
        compose.onNodeWithText("Unstar conversation").performClick()

        compose.runOnIdle { assertEquals(listOf("!general:example.org" to true, "!sam:example.org" to false), starred) }
        compose.onNodeWithText("Star channel").assertDoesNotExist()
    }

    // capability: conversation.mark-read
    // capability: conversation.mark-unread
    @Test fun longPressingAConversationMarksItReadOrUnreadAtOnceOrEveryConversationRead() {
        val marked = mutableListOf<Pair<String, Boolean>>()
        var all = 0
        val rooms = listOf(channel("!general:example.org", "general").copy(unread = UnreadBadge.Bold),
            channel("!random:example.org", "random"))
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {},
                    onMarkUnread = { id, unread -> marked += id to unread; true }, onMarkAllRead = { all++; true })
            }
        }
        compose.onNodeWithText("general").performTouchInput { longClick() }
        compose.onNodeWithText("Mark unread").assertDoesNotExist()
        compose.onNodeWithText("Mark as read").performClick()
        // Read at once, though the server hasn't answered.
        compose.onNodeWithText("general").assert(SemanticsMatcher.keyNotDefined(SemanticsProperties.StateDescription))
        compose.onNodeWithText("random").performTouchInput { longClick() }
        compose.onNodeWithText("Mark unread").performClick()
        compose.onNodeWithText("random").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Unread"))
        compose.onNodeWithText("random").performTouchInput { longClick() }
        compose.onNodeWithText("Mark all as read").performClick()

        compose.runOnIdle {
            assertEquals(listOf("!general:example.org" to false, "!random:example.org" to true), marked)
            assertEquals(1, all)
        }
    }

    @Test fun aReadStateThatDoesNotSaveSaysSoAndGoesBack() {
        val rooms = listOf(channel("!general:example.org", "general").copy(unread = UnreadBadge.Bold))
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {},
                    onMarkUnread = { _, _ -> false })
            }
        }
        compose.onNodeWithText("general").performTouchInput { longClick() }
        compose.onNodeWithText("Mark as read").performClick()
        compose.onNodeWithText("Couldn’t mark general as read.").assertIsDisplayed()
        compose.onNodeWithText("general").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Unread"))
    }

    @Test fun aStarredConversationMovesToStarredBeforeTheServerAnswers() {
        val saved = CompletableDeferred<Boolean>()
        val rooms = listOf(channel("!general:example.org", "general"), channel("!random:example.org", "random"))
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true), {}, {}, {},
                    onStar = { _, _ -> saved.await() })
            }
        }
        compose.onNodeWithText("general").performTouchInput { longClick() }
        compose.onNodeWithText("Star channel").performClick()

        assertTrue(top("Starred") < top("general") && top("general") < top("Channels"))
        saved.complete(false)
        compose.onNodeWithText("Couldn’t star general.").assertIsDisplayed()
        compose.onNodeWithText("Starred").assertDoesNotExist()
    }

    @Test fun aStarThatDoesNotSaveSaysSo() {
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(listOf(channel("!general:example.org", "general")), loading = false, spacesKnown = true),
                    {}, {}, {}, onStar = { _, _ -> false })
            }
        }
        compose.onNodeWithText("general").performTouchInput { longClick() }
        compose.onNodeWithText("Star channel").performClick()
        compose.onNodeWithText("Couldn’t star general.").assertIsDisplayed()
    }

    // capability: home.dms
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

    // capability: home.unread-badges
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

    // capability: auth.sign-out
    @Test fun youIsAPageWithPreferencesSignOutAndBack() {
        var preferences = false
        var signedOut = false
        var back = false
        compose.setContent {
            SlatrixTheme { LiveYouScreen("@alex:example.org", { null }, { preferences = true }, { signedOut = true }, { back = true }) }
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

    // capability: profile.own
    @Test fun youShowsTheNameOnTheAccountsProfile() {
        compose.setContent { SlatrixTheme { LiveYouScreen("@alex:example.org", { "Alex Doe" }, {}, {}, {}) } }
        compose.onNodeWithText("Alex Doe").assertIsDisplayed()
        compose.onNodeWithText("@alex:example.org").assertIsDisplayed()
    }

    // capability: home.conversations
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

    // capability: home.workspace-switcher
    @Test fun theWorkspaceIconAndNameOpenASwitcherOfTopLevelWorkspaces() {
        val chosen = mutableListOf<String?>()
        val spaces = listOf(SpaceSummary("!design:example.org", "Design", isTopLevel = false),
            SpaceSummary("!harbor:example.org", "Harbor"), SpaceSummary("!studio:example.org", "Studio"))
        val rooms = listOf(channel("!work:example.org", "work").copy(spaceIds = setOf("!harbor:example.org")))
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spaces = spaces, spacesKnown = true), {}, {}, {},
                    "!harbor:example.org", { chosen += it })
            }
        }
        compose.onNode(hasText("Harbor") and hasContentDescription("Switch workspace")).assertIsDisplayed()
        compose.onNodeWithContentDescription("Switch workspace").performClick()

        compose.onNode(hasText("Harbor") and hasAnyAncestor(isDialog())).assertIsSelected()
        compose.onNode(hasText("Design") and hasAnyAncestor(isDialog())).assertDoesNotExist()
        // Every channel has a workspace, so there is nothing for All to add.
        compose.onNodeWithText("All conversations").assertDoesNotExist()
        compose.onNode(hasText("Studio") and hasAnyAncestor(isDialog())).performClick()
        compose.runOnIdle { assertEquals(listOf<String?>("!studio:example.org"), chosen) }
        compose.onNode(isDialog()).assertDoesNotExist()
    }

    @Test fun aSavedWorkspaceStillLoadingNeverFlashesAllConversations() {
        compose.setContent {
            SlatrixTheme { LiveHomeScreen("@alex:example.org", RoomListState(loading = false), {}, {}, {}, "!harbor:example.org") }
        }
        compose.onNodeWithContentDescription("Switch workspace").assertExists()
        compose.onNodeWithText("All conversations").assertDoesNotExist()
    }

    @Test fun allConversationsJoinsTheSwitcherWhileAChannelHasNoWorkspace() {
        val chosen = mutableListOf<String?>()
        val rooms = listOf(channel("!work:example.org", "work").copy(spaceIds = setOf("!harbor:example.org")), channel("!loose:example.org", "loose"))
        compose.setContent {
            SlatrixTheme {
                LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spaces = listOf(SpaceSummary("!harbor:example.org", "Harbor")),
                    spacesKnown = true), {}, {}, {}, "!harbor:example.org", { chosen += it })
            }
        }
        compose.onNodeWithContentDescription("Switch workspace").performClick()
        compose.onNode(hasText("All conversations") and hasAnyAncestor(isDialog())).performClick()
        compose.runOnIdle { assertEquals(listOf<String?>(null), chosen) }
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

    private fun top(text: String) = compose.onNodeWithText(text).fetchSemanticsNode().boundsInRoot.top

    private fun channel(id: String, name: String) = RoomSummary(id, name, false, "", UnreadBadge.None, name.take(1), 0)

    private fun direct(id: String, name: String, unread: UnreadBadge = UnreadBadge.None, latest: LatestMessage? = null) =
        RoomSummary(id, name, true, "", unread, name.split(" ").joinToString("") { it.take(1) }, 0, latest = latest)
}
