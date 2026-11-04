package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ActivityItem
import ai.nuanu.slatrix.core.ActivityKind
import ai.nuanu.slatrix.core.MessageSearchState
import ai.nuanu.slatrix.core.NotifyAbout
import ai.nuanu.slatrix.ui.account.AccountProviderScreen
import ai.nuanu.slatrix.ui.account.ActivityScreen
import ai.nuanu.slatrix.ui.account.LivePreferencesScreen
import ai.nuanu.slatrix.ui.account.LiveYouScreen
import ai.nuanu.slatrix.ui.account.NotificationRows
import ai.nuanu.slatrix.ui.account.SearchScreen
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onNodeWithContentDescription
import ai.nuanu.slatrix.core.ChannelDirectoryState
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.DirectoryChannel
import ai.nuanu.slatrix.core.LatestMessage
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.MessageThread
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SavedMessage
import ai.nuanu.slatrix.core.SavedPreview
import ai.nuanu.slatrix.core.SpaceSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.BrowseChannelsScreen
import ai.nuanu.slatrix.ui.account.LaterScreen
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.MessageActions
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.Density
import com.github.takahirom.roborazzi.captureScreenRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.util.Calendar

/**
 * Renders each restyled screen with fictional data at 320, 360 and 412 dp wide and font scales from 0.85 to 2.0, plus
 * 320 at 1.15 as a OnePlus with its density raised, so clipping and overlap show wherever the space is tightest.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35])
class PhoneSizeScreenshots(private val screen: String, private val width: Int, private val fontScale: Float, private val dark: Boolean) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        RuntimeEnvironment.setQualifiers("w${width}dp-h${width * 2 + 64}dp-xxhdpi")
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale)) {
                SlatrixTheme(dark = dark) { Box(Modifier.fillMaxSize().background(SlatrixTheme.colors.canvas)) { Screen() } }
            }
        }
        when (screen) {
            "Menu" -> compose.onNodeWithText("Looking now.", substring = true).performTouchInput { longClick() }
            "DMs" -> compose.onNode(hasText("DMs") and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected)).performClick()
            "Switcher" -> compose.onNodeWithContentDescription("Switch workspace").performClick()
            "Search" -> compose.onNodeWithText("Search Harbor").performClick()
        }
        compose.waitForIdle()
        captureScreenRoboImage("build/outputs/roborazzi/Phone-$screen-$width-$fontScale-${if (dark) "dark" else "light"}.png")
    }

    @androidx.compose.runtime.Composable
    private fun Screen() {
        val now = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 12); set(Calendar.MINUTE, 7) }.timeInMillis
        val hour = 3_600_000L
        val room = RoomSummary("!design:example.org", "design", false, "Launch reviews and critique", UnreadBadge.None, "D", 0,
            memberCount = 7)
        fun message(id: String, sender: String, body: String, minutes: Int) = ConversationMessage(id, "\$$id",
            "@${sender.lowercase()}:example.org", sender, body, null, now + minutes * 60_000L, MessageKind.Text, MessageSendState.Sent,
            sender == "Jordan", sender.take(1), if (sender == "Mira") 2 else 5)
        val conversation = listOf(
            message("a", "Mira", "Morning! The new onboarding flow is up on staging.\n\nWould love eyes on the empty states before Friday.", 0)
                .copy(thread = MessageThread(3, "Jordan", now + 20 * 60_000L)),
            message("b", "Dev", "I'll take the first pass.", 2),
            message("c", "Jordan", "Looking now. The illustrations read well in dark mode too.", 4),
            message("d", "Jordan", "One more pass after lunch.", 5).copy(grouped = true),
        )
        val rooms = listOf(
            RoomSummary("!wm:example.org", "Wanda Moss", true, "", UnreadBadge.Count("2"), "WM", 1,
                latest = LatestMessage("Can you look at the release notes before lunch?", now - hour, own = false)),
            RoomSummary("!design:example.org", "design", false, "", UnreadBadge.Count("1"), "D", 0, spaceIds = setOf(Harbor),
                latest = LatestMessage("The new onboarding flow is up on staging", now - 2 * hour, own = false)),
            RoomSummary("!general:example.org", "general", false, "", UnreadBadge.None, "G", 2, spaceIds = setOf(Harbor),
                latest = LatestMessage("Lunch is on the roof today", now - 26 * hour, own = true)),
            RoomSummary("!plans:example.org", "launch-plans", false, "", UnreadBadge.None, "L", 5, isPrivate = true, spaceIds = setOf(Harbor)),
        )
        when (screen) {
            "Home", "DMs", "Switcher", "Search" -> LiveHomeScreen("@alex:example.org", RoomListState(rooms,
                loading = false, spaces = listOf(SpaceSummary(Harbor, "Harbor")), spacesKnown = true),
                {}, {}, {}, Harbor, onBrowseChannels = {}, onCreateChannel = {}, onNewMessage = {},
                search = { onClose -> SearchScreen(rooms, "@alex:example.org", MessageSearchState(), {}, {}, {}, onClose = onClose, onRoom = {}) })
            "Activity" -> ActivityScreen(listOf(
                ActivityItem("a", "!design:example.org", "\$1", "design", false, "Mira Chen", "MC", 2,
                    "@Alex could you take a look at the launch checklist before Friday?", now - hour, ActivityKind.Mention, null),
                ActivityItem("b", "!wm:example.org", "\$2", "Wanda Moss", true, "Wanda Moss", "WM", 1,
                    "Can you look at the release notes before lunch?", now - 2 * hour, ActivityKind.Message, null).copy(unread = false),
            ), {}, { _, _ -> })
            "You" -> LiveYouScreen("@alexandra.rivera:harbor-collective.example.org", { "Alexandra Rivera" }, {}, {}, onBack = {})
            "Preferences" -> LivePreferencesScreen(dark, null, false, {}, {}, {}) { NotificationRows(NotifyAbout.DirectAndMentions, true, null, {}, {}) }
            "SignIn" -> AccountProviderScreen("", {}, connecting = false, error = null, onContinue = {}, onCancel = {})
            "Channel", "Menu" -> LiveChannelScreen(room, ConversationState(conversation, loading = false, hasMore = false),
                ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                actions = MessageActions(quick = listOf("🙂", "❤️", "👍", "💯", "🐛"), recent = listOf("🙂", "❤️", "👍"),
                    onReact = { _, _ -> }, link = { "" }, onDelete = {}, onQuote = {}, onEdit = {}, onForward = {}, onPin = { _, _ -> },
                    onMarkUnread = {}))
            "Thread" -> LiveChannelScreen(room, ConversationState(listOf(conversation[0].copy(thread = null),
                message("r1", "Jordan", "Works for me.", 10), message("r2", "Mira", "Great, sending the invite now.", 20)),
                loading = false, hasMore = false), ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {}, threadRoot = "\$a")
            "Browse" -> BrowseChannelsScreen("Harbor", ChannelDirectoryState(listOf(
                DirectoryChannel("!design:example.org", "design", "Reviews and crits", 12, canJoin = true),
                DirectoryChannel("!general:example.org", "general", "Company-wide announcements and work-based matters", 40, canJoin = true),
                DirectoryChannel("!board:example.org", "board", null, 3, canJoin = false, rule = "Invite only"),
            ), loading = false), joined = setOf("!general:example.org"), joining = null, error = null, onSearch = {}, onMore = {},
                onChannel = {}, onBack = {})
            "Later" -> {
                val previews = mapOf(
                    "\$a" to SavedPreview("@mira:example.org", "Mira Chen", "The new onboarding flow is up on staging. Would love eyes on the empty states.", now - hour),
                    "\$b" to SavedPreview("@wanda:example.org", "Wanda Moss", "Can you look at the release notes before lunch?", now - 26 * hour),
                )
                LaterScreen(listOf(SavedMessage("!design:example.org", "\$a", 2), SavedMessage("!wm:example.org", "\$b", 1)),
                    listOf(room, RoomSummary("!wm:example.org", "Wanda Moss", true, "", UnreadBadge.None, "WM", 1)),
                    { previews[it.eventId] }, {}, {})
            }
        }
    }

    companion object {
        private const val Harbor = "!harbor:example.org"
        private val Phones = listOf(320, 360, 412).flatMap { width -> listOf(0.85f, 1f, 1.3f, 2f).map { width to it } } + (320 to 1.15f)

        @JvmStatic @Parameters(name = "{0}-{1}-{2}-dark={3}")
        fun cases(): List<Array<Any>> = buildList {
            for (screen in listOf("Home", "DMs", "Switcher", "Search", "Activity", "Later", "You", "Preferences", "Channel", "Thread",
                "Menu", "Browse", "SignIn")) {
                for ((width, scale) in Phones) add(arrayOf(screen, width, scale, false))
                add(arrayOf(screen, 412, 1f, true))
            }
        }
    }
}
