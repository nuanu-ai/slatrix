package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SpaceSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.LocalGlassActive
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.glass
import ai.nuanu.slatrix.ui.designsystem.glassBar
import ai.nuanu.slatrix.ui.designsystem.glassSource
import ai.nuanu.slatrix.ui.designsystem.rememberGlass
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.chrisbanes.haze.HazeState
import org.junit.Assert.assertTrue
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.runtime.CompositionLocalProvider
import org.junit.Assert.assertEquals
import ai.nuanu.slatrix.ui.account.LiveWorkspace
import ai.nuanu.slatrix.ui.account.WorkspaceCover
import androidx.activity.compose.BackHandler
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import org.junit.Assert.assertFalse
import androidx.compose.runtime.produceState
import androidx.compose.runtime.snapshots.Snapshot
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class LiveWorkspaceTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun anUnreadRoomOpensFromTheLiveHome() {
        val rooms = RoomListState(listOf(RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.Count("3"), "T", 0)), loading = false)
        var opened: String? = null
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", rooms, { opened = it }, {}, {}) } }
        compose.onNodeWithText("3").assertExists()
        compose.onNodeWithText("Team").performClick()
        compose.runOnIdle { assertEquals("!team:example.org", opened) }
    }

    // capability: home.workspace-switcher
    @Test fun choosingATestWorkspaceHidesOtherWorkspacesChannels() {
        val nuanu = RoomSummary("!work:example.org", "Work channel", false, "", UnreadBadge.None, "W", 0, setOf("!nuanu:example.org"))
        val test = RoomSummary("!test:example.org", "Test channel", false, "", UnreadBadge.None, "T", 1, setOf("!studio:example.org"))
        val direct = RoomSummary("!sam:example.org", "Sam", true, "", UnreadBadge.None, "S", 2)
        val rooms = RoomListState(listOf(nuanu, test, direct), loading = false, spacesKnown = true, spaces = listOf(
            SpaceSummary("!nuanu:example.org", "Nuanu", true, "N", 0),
            SpaceSummary("!studio:example.org", "Test Studio", true, "TS", 1),
        ))
        val selected = mutableStateOf<String?>(null)
        compose.setContent { SlatrixTheme { LiveHomeScreen("@alex:example.org", rooms, {}, {}, {}, selected.value, { selected.value = it }) } }
        compose.onNodeWithContentDescription("Switch workspace").performClick()
        compose.onNodeWithText("Test Studio").performClick()
        compose.onNodeWithText("Test channel").assertExists()
        compose.onNodeWithText("Sam").assertExists()
        compose.onNodeWithText("Work channel").assertDoesNotExist()
    }

    // capability: composer.send
    @Test fun theComposerStaysEditableWhileThePreviousMessageIsSending() {
        val room = RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)
        val draft = mutableStateOf(ComposerState(text = "First message", loading = false))
        var submitted: String? = null
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(loading = false), draft.value,
                    { draft.value = draft.value.copy(text = it) },
                    { submitted = draft.value.text; draft.value = draft.value.copy(sending = true) }, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNode(hasContentDescription("Message #Team") and hasSetTextAction()).performClick()
        compose.onNodeWithContentDescription("Send message").performClick()
        compose.runOnIdle { assertEquals("First message", submitted) }
        compose.onNodeWithContentDescription("Message #Team").performTextReplacement("Another thought")
        compose.runOnIdle { assertEquals("Another thought", draft.value.text) }
    }

    // Back to a profile redrew it from nothing: its photo from an empty circle, its name small and then full size.
    @Test fun aPageUnderAnotherIsAsItWasWhenItShowsAgain() {
        val editing = mutableStateOf(false)
        compose.setContent {
            SlatrixTheme {
                LiveWorkspace(listOfNotNull(
                    WorkspaceCover("profile") {
                        val name by produceState("…") { value = "Mira Chen" }
                        Text("Profile of $name")
                    },
                    WorkspaceCover("edit") { Text("Edit profile") }.takeIf { editing.value },
                )) { Text("Home") }
            }
        }
        compose.onNodeWithText("Profile of Mira Chen").assertIsDisplayed()
        compose.runOnIdle { editing.value = true }
        compose.onNodeWithText("Edit profile").assertIsDisplayed()
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { editing.value = false; Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Profile of Mira Chen").assertIsDisplayed()
    }

    @Test fun aConversationUnderAnotherPageReadsNothingAndTakesNoBack() {
        val room = RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)
        fun message(id: String) = ConversationMessage(id, "\$$id", "@sam:example.org", "Sam", id, null,
            0, MessageKind.Text, MessageSendState.Sent, false, "S", 0)
        val timeline = mutableStateOf(ConversationState(listOf(message("First")), loading = false, hasMore = false))
        val profile = mutableStateOf(false)
        var read: String? = null
        var left = false
        compose.setContent {
            SlatrixTheme {
                LiveWorkspace(listOfNotNull(
                    WorkspaceCover("team") {
                        LiveChannelScreen(room, timeline.value, ComposerState(loading = false), {}, {}, { left = true }, {}, { read = it }, {}, {}, {})
                    },
                    WorkspaceCover("profile") { BackHandler { profile.value = false }; Text("Profile") }.takeIf { profile.value },
                )) { Text("Home") }
            }
        }
        compose.waitUntil { read == "\$First" }
        compose.runOnIdle { profile.value = true }
        compose.onNodeWithText("Profile").assertIsDisplayed()
        compose.runOnIdle { timeline.value = timeline.value.copy(rows = timeline.value.rows + message("Next")) }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals("\$First", read) }
        compose.runOnIdle { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithText("Next").assertIsDisplayed()
        compose.runOnIdle { assertFalse("Back closed the page on top, not the conversation under it", left) }
        compose.waitUntil { read == "\$Next" }
    }

    // capability: conversation.read
    @Test fun onlyTheLatestVisibleMessageIsReadWhileTheActivityIsResumed() {
        val room = RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)
        fun message(id: String) = ConversationMessage(id, "\$$id", "@sam:example.org", "Sam", id, null,
            0, MessageKind.Text, MessageSendState.Sent, false, "S", 0)
        val timeline = mutableStateOf(ConversationState(listOf(message("First")), loading = false, hasMore = false))
        val owner = object : LifecycleOwner { override val lifecycle = LifecycleRegistry(this) }
        compose.runOnUiThread { owner.lifecycle.currentState = Lifecycle.State.RESUMED }
        var read: String? = null
        compose.setContent {
            SlatrixTheme { CompositionLocalProvider(LocalLifecycleOwner provides owner) {
                LiveChannelScreen(room, timeline.value, ComposerState(loading = false), {}, {}, {}, {}, { read = it }, {}, {}, {})
            } }
        }
        compose.onNodeWithText("First").assertExists()
        compose.waitUntil { read == "\$First" }
        compose.runOnIdle {
            owner.lifecycle.currentState = Lifecycle.State.STARTED
            timeline.value = timeline.value.copy(rows = timeline.value.rows + message("Next"))
        }
        compose.onNodeWithText("Next").assertIsDisplayed()
        compose.runOnIdle { assertEquals("\$First", read) }
        compose.runOnIdle { owner.lifecycle.currentState = Lifecycle.State.RESUMED }
        compose.waitForIdle()
        compose.waitUntil { read == "\$Next" }
    }

    // capability: conversation.read
    @Test fun anUpdatedAckTokenMarksTheLatestVisibleMessageReadAgain() {
        val room = RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)
        fun message(id: String) = ConversationMessage(id, "\$$id", "@sam:example.org", "Sam", id, null,
            0, MessageKind.Text, MessageSendState.Sent, false, "S", 0)
        val timeline = mutableStateOf(ConversationState(listOf(message("First")), loading = false, hasMore = false))
        val reads = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, timeline.value, ComposerState(loading = false), {}, {}, {}, {}, { reads += it }, {}, {}, {})
            }
        }
        compose.waitUntil { reads.size == 1 }
        compose.runOnIdle { timeline.value = timeline.value.copy(ackToken = timeline.value.ackToken + 1) }
        compose.waitForIdle()
        assertEquals(listOf("\$First", "\$First"), reads)
    }

    // capability: conversation.read
    @Test fun anUndecryptedLatestMessageIsNotMarkedReadUntilItDecrypts() {
        val room = RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)
        fun message(id: String, kind: MessageKind) = ConversationMessage(id, "\$$id", "@sam:example.org", "Sam", id, null,
            0, kind, MessageSendState.Sent, false, "S", 0)
        val timeline = mutableStateOf(ConversationState(listOf(message("First", MessageKind.Encrypted)), loading = false, hasMore = false))
        val reads = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, timeline.value, ComposerState(loading = false), {}, {}, {}, {}, { reads += it }, {}, {}, {})
            }
        }
        compose.waitForIdle()
        assertEquals(emptyList<String>(), reads)

        compose.runOnIdle { timeline.value = timeline.value.copy(rows = listOf(message("First", MessageKind.Text))) }
        compose.waitForIdle()
        assertEquals(listOf("\$First"), reads)
    }

    // capability: conversation.jump-to-message
    @Test fun whileSeekingAThreadJumpTargetLiveChannelScreenHoldsBackAutoRead() {
        val room = RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)
        val latest = ConversationMessage("Latest", "\$Latest", "@sam:example.org", "Sam", "Latest", null,
            0, MessageKind.Text, MessageSendState.Sent, false, "S", 0)
        val timeline = mutableStateOf(ConversationState(listOf(latest), loading = false, hasMore = false, seekingTarget = true))
        val reads = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, timeline.value, ComposerState(loading = false), {}, {}, {}, {}, { reads += it }, {}, {}, {})
            }
        }
        compose.waitForIdle()
        assertEquals("Must not mark newest reply read while paginating backwards for an older jump target",
            emptyList<String>(), reads)

        compose.runOnIdle { timeline.value = timeline.value.copy(seekingTarget = false) }
        compose.waitForIdle()
        assertEquals(listOf("\$Latest"), reads)
    }

    // capability: conversation.read
    @Test fun reconnectingRetriesMarkingTheLatestVisibleMessageRead() {
        val room = RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)
        val msg = ConversationMessage("First", "\$First", "@sam:example.org", "Sam", "Hello", null,
            0, MessageKind.Text, MessageSendState.Sent, false, "S", 0)
        val connection = kotlinx.coroutines.flow.MutableStateFlow(ai.nuanu.slatrix.core.ConnectionState.Offline)
        val reads = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                ai.nuanu.slatrix.ui.account.ProvideConnection(connection) {
                    LiveChannelScreen(room, ConversationState(listOf(msg), loading = false, hasMore = false),
                        ComposerState(loading = false), {}, {}, {}, {}, { reads += it }, {}, {}, {})
                }
            }
        }
        compose.waitForIdle()
        assertEquals(1, reads.size)

        connection.value = ai.nuanu.slatrix.core.ConnectionState.Connected
        compose.waitForIdle()
        assertEquals(2, reads.size)

        connection.value = ai.nuanu.slatrix.core.ConnectionState.Offline
        compose.waitForIdle()
        assertEquals("Going offline must not fire a wasted read", 2, reads.size)

        connection.value = ai.nuanu.slatrix.core.ConnectionState.Connected
        compose.waitForIdle()
        assertEquals(3, reads.size)
    }

    // capability: activity.badge
    @Test fun aThreadMarksActivityRepliesReadOnlyWhileResumed() {
        val room = RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main.immediate)
        val activity = ai.nuanu.slatrix.core.MatrixActivity("@alex:example.org", scope) { _, _ -> null }
        fun reply(id: String, at: ULong) = org.matrix.rustcomponents.sdk.NotificationItem(
            event = org.matrix.rustcomponents.sdk.NotificationEvent.Timeline(object : org.matrix.rustcomponents.sdk.TimelineEvent(org.matrix.rustcomponents.sdk.NoHandle) {
                override fun content() = org.matrix.rustcomponents.sdk.TimelineEventContent.MessageLike(
                    org.matrix.rustcomponents.sdk.MessageLikeEventContent.RoomMessage(
                        org.matrix.rustcomponents.sdk.MessageType.Text(org.matrix.rustcomponents.sdk.TextMessageContent(id, null)), null))
                override fun eventId() = id
                override fun senderId() = "@sam:example.org"
                override fun timestamp() = at
                override fun threadRootEventId() = "\$root"
            }),
            rawEvent = "{}", senderInfo = org.matrix.rustcomponents.sdk.NotificationSenderInfo("Sam", null, false),
            roomInfo = org.matrix.rustcomponents.sdk.NotificationRoomInfo("Team", null, null, null, null, 2u, 0u, emptyList(), true, false, false, false),
            isNoisy = true, hasMention = false, threadId = "\$root", actions = null,
        )
        activity.listener.onNotification(reply("\$r1", 1_000u), "!team:example.org")
        val owner = object : LifecycleOwner { override val lifecycle = LifecycleRegistry(this) }
        compose.runOnUiThread { owner.lifecycle.currentState = Lifecycle.State.RESUMED }
        val media = ai.nuanu.slatrix.core.MatrixMedia(object : org.matrix.rustcomponents.sdk.Client(org.matrix.rustcomponents.sdk.NoHandle) {},
            "@alex:example.org", compose.activity.cacheDir)
        try {
            compose.setContent {
                SlatrixTheme {
                    CompositionLocalProvider(LocalLifecycleOwner provides owner) {
                        ai.nuanu.slatrix.ui.account.LiveConversation(
                            ai.nuanu.slatrix.core.OpenChannel(room, threadRoot = "\$root"),
                            null, null, { _, _, _ -> }, null, media, emptyList(), { _, _, _ -> }, null, { _, _ -> },
                            activity = activity,
                        )
                    }
                }
            }
            compose.waitUntil { activity.items.value.singleOrNull()?.unread == false }

            // Locking the phone drops lifecycle below RESUMED: incoming thread replies must stay unread!
            compose.runOnIdle { owner.lifecycle.currentState = Lifecycle.State.STARTED }
            compose.waitForIdle()
            activity.listener.onNotification(reply("\$r2", 2_000u), "!team:example.org")
            compose.waitForIdle()
            assertEquals(listOf("\$r2"), activity.items.value.filter { it.unread }.map { it.eventId })

            // Resuming the screen clears them.
            compose.runOnIdle { owner.lifecycle.currentState = Lifecycle.State.RESUMED }
            compose.waitUntil { activity.items.value.none { it.unread } }
        } finally {
            activity.close()
            scope.coroutineContext[kotlinx.coroutines.Job]?.cancel()
        }
    }

    @Test fun leavingAPageDiscardsItsSavedStateSoReopeningStartsFresh() {
        val open = mutableStateOf(true)
        var mutate: (() -> Unit)? = null
        compose.setContent {
            SlatrixTheme {
                LiveWorkspace(listOfNotNull(
                    WorkspaceCover("channel-a") {
                        var marker by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf("fresh") }
                        mutate = { marker = "scrolled" }
                        Text("Marker: $marker")
                    }.takeIf { open.value },
                )) { Text("Home") }
            }
        }
        compose.onNodeWithText("Marker: fresh").assertIsDisplayed()
        compose.runOnIdle { mutate?.invoke() }
        compose.onNodeWithText("Marker: scrolled").assertIsDisplayed()
        compose.runOnIdle { open.value = false }
        compose.onNodeWithText("Home").assertIsDisplayed()
        compose.runOnIdle { open.value = true }
        compose.onNodeWithText("Marker: fresh").assertIsDisplayed()
    }

    @Test fun coveredAndExitingPagesDisableLiveGlassWhileTopPageKeepsItActive() {
        val stack = mutableStateOf(emptyList<String>())
        var homeGlass = false
        var channelGlass = false
        var threadGlass = false
        compose.setContent {
            SlatrixTheme {
                LiveWorkspace(stack.value.map { key ->
                    WorkspaceCover(key) {
                        when (key) {
                            // Nested LiveWorkspace inside Channel must inherit inactive glass when Channel is covered by Thread.
                            "channel" -> LiveWorkspace(emptyList()) {
                                channelGlass = LocalGlassActive.current
                                Text("Channel")
                            }
                            else -> {
                                threadGlass = LocalGlassActive.current
                                Text("Thread")
                            }
                        }
                    }
                }) {
                    homeGlass = LocalGlassActive.current
                    Text("Home")
                }
            }
        }
        compose.waitForIdle()
        assertTrue("Home has active glass while uncovered", homeGlass)

        compose.runOnIdle { stack.value = listOf("channel") }
        compose.waitForIdle()
        assertFalse("Home disables glass when covered by a channel", homeGlass)
        assertTrue("Top channel has active glass", channelGlass)

        compose.runOnIdle { stack.value = listOf("channel", "thread") }
        compose.waitForIdle()
        assertFalse("Home keeps glass disabled at depth 2", homeGlass)
        assertFalse("Covered channel (and its nested workspace) disables glass", channelGlass)
        assertTrue("Top thread has active glass", threadGlass)

        // Mid-pop exit: the sliding-out thread disables live glass immediately while the revealed channel turns it back on.
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { stack.value = listOf("channel"); Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        assertFalse("Exiting thread disables live glass immediately during slide-out", threadGlass)
        assertTrue("Revealed channel activates live glass", channelGlass)
        assertFalse("Home remains covered with glass disabled", homeGlass)
        compose.mainClock.advanceTimeBy(1_000)
        assertTrue(channelGlass)
    }

    @Test fun inactiveGlassSkipsHazeSourceAndEffectRegistrations() {
        val active = mutableStateOf(true)
        lateinit var glassState: HazeState
        var barModifier: Modifier = Modifier
        var capsuleModifier: Modifier = Modifier
        fun Modifier.hasHazeEffect() = foldIn(false) { acc, element ->
            acc || element.javaClass.name.startsWith("dev.chrisbanes.haze.")
        }
        compose.setContent {
            SlatrixTheme {
                CompositionLocalProvider(LocalGlassActive provides active.value) {
                    val glass = rememberGlass()
                    glassState = glass
                    barModifier = Modifier.size(48.dp).glassBar(glass)
                    capsuleModifier = Modifier.size(48.dp).glass(glass, SlatrixTheme.colors.glass, CircleShape)
                    Box(Modifier.fillMaxSize()) {
                        Box(Modifier.fillMaxSize().glassSource(glass))
                        Box(barModifier)
                        Box(capsuleModifier)
                    }
                }
            }
        }
        compose.waitForIdle()
        assertTrue("Active glass registers its Haze source area", glassState.areas.isNotEmpty())
        assertTrue("Active glassBar attaches Haze effect", barModifier.hasHazeEffect())
        assertTrue("Active glass attaches Haze effect", capsuleModifier.hasHazeEffect())

        compose.runOnIdle { active.value = false }
        compose.waitForIdle()
        assertTrue("Inactive glass unregisters Haze areas", glassState.areas.isEmpty())
        assertFalse("Inactive glassBar falls back to translucent tint without Haze effect", barModifier.hasHazeEffect())
        assertFalse("Inactive glass falls back to translucent tint without Haze effect", capsuleModifier.hasHazeEffect())
    }

    @Test fun pushingAPageDisablesLiveGlassUntilTheSlideSettles() {
        val stack = mutableStateOf(emptyList<String>())
        var channelGlass = true
        compose.setContent {
            SlatrixTheme {
                LiveWorkspace(stack.value.map { key ->
                    WorkspaceCover(key) {
                        channelGlass = LocalGlassActive.current
                        Text("Channel")
                    }
                }) { Text("Home") }
            }
        }
        compose.waitForIdle()

        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { stack.value = listOf("channel"); Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        assertFalse("Pushing page must disable live blur while sliding in", channelGlass)

        compose.mainClock.advanceTimeBy(1_000)
        assertTrue("Top page activates live blur once the slide settles", channelGlass)
    }
}
