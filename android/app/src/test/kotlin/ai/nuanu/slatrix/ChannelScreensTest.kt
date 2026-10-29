package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ChannelDirectoryState
import ai.nuanu.slatrix.core.DirectoryChannel
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.BrowseChannelsScreen
import ai.nuanu.slatrix.ui.account.CreateChannelScreen
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Finding, joining and creating channels: Home's entry points, Browse channels and the new channel form. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class ChannelScreensTest {
    @get:Rule val compose = createComposeRule()
    private val general = RoomSummary("!general:example.org", "general", false, "", UnreadBadge.None, "G", 0)
    private val opened = mutableListOf<String>()

    private fun home() = compose.setContent {
        SlatrixTheme {
            LiveHomeScreen("@alex:example.org", RoomListState(listOf(general), loading = false, spacesKnown = true), {}, {}, {},
                onBrowseChannels = { opened += "browse" }, onCreateChannel = { opened += "create" })
        }
    }

    // capability: home.browse-channels
    @Test fun channelsHeaderOpensBrowseChannelsAndItsArrowStillCollapses() {
        home()
        compose.onNodeWithText("Channels").performClick()
        compose.runOnIdle { assertEquals(listOf("browse"), opened) }
        compose.onNodeWithContentDescription("Channels").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Expanded"))
            .performClick()
        compose.onNodeWithText("general").assertDoesNotExist()
    }

    // capability: home.browse-channels
    // capability: home.create-channel
    @Test fun addChannelOffersBrowsingOrCreating() {
        home()
        compose.onNodeWithText("Add channel").performClick()
        compose.onNodeWithText("Browse channels").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Add channel").performClick()
        compose.onNodeWithText("Create a channel").performClick()
        compose.runOnIdle { assertEquals(listOf("browse", "create"), opened) }
    }

    // capability: home.browse-channels
    @Test fun browseListsChannelsAndJoinsOnlyThoseYouMayJoin() {
        val searched = mutableListOf<String>()
        val picked = mutableListOf<String>()
        val design = DirectoryChannel("!design:example.org", "design", "Reviews and crits", 12, canJoin = true)
        compose.setContent {
            SlatrixTheme {
                BrowseChannelsScreen("Harbor", ChannelDirectoryState(listOf(design,
                    DirectoryChannel("!board:example.org", "board", null, 3, canJoin = false, rule = "Invite only"),
                    DirectoryChannel(general.id, "general", null, 40, canJoin = true))), joined = setOf(general.id), joining = null,
                    error = null, onSearch = { searched += it }, onMore = {}, onChannel = { picked += it.id }, onBack = {})
            }
        }
        compose.onNodeWithText("12 members · Reviews and crits").assertIsDisplayed()
        compose.onNodeWithText("Joined").assertIsDisplayed()
        compose.onNodeWithText("3 members · Invite only").assertIsDisplayed()
        compose.onNodeWithText("board").performClick()
        compose.onNodeWithText("design").performClick()
        compose.onNodeWithText("general").performClick()
        compose.onNode(hasSetTextAction()).performTextInput("des")
        compose.runOnIdle {
            assertEquals(listOf(design.id, general.id), picked)
            assertEquals("des", searched.last())
        }
    }

    // capability: home.create-channel
    @Test fun aNewChannelNeedsANameAndCreatesWithItsTopic() {
        val created = mutableListOf<Pair<String, String>>()
        compose.setContent {
            SlatrixTheme { CreateChannelScreen("Harbor", creating = false, error = null, onCreate = { name, topic -> created += name to topic }, onBack = {}) }
        }
        compose.onNodeWithText("Create").assertIsNotEnabled()
        compose.onNode(hasSetTextAction() and hasText("Name", substring = true)).performTextInput("launch-plans")
        compose.onNode(hasSetTextAction() and hasText("Topic", substring = true)).performTextInput("Dates and owners")
        compose.onNodeWithText("Create").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(listOf("launch-plans" to "Dates and owners"), created) }
    }
}
