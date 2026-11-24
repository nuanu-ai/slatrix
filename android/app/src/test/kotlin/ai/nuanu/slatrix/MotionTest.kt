package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ComposerTarget
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageAttachment
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ChannelDetailsActions
import ai.nuanu.slatrix.ui.account.ChannelDetailsScreen
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.account.LivePreferencesScreen
import ai.nuanu.slatrix.ui.account.MessageActions
import ai.nuanu.slatrix.ui.account.MessageActionsHost
import ai.nuanu.slatrix.ui.designsystem.BottomSheet
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.activity.BackEventCompat
import androidx.activity.OnBackPressedDispatcher
import androidx.activity.compose.LocalOnBackPressedDispatcherOwner
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.semantics.SemanticsActions
import java.io.ByteArrayOutputStream
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNotEquals
import androidx.compose.ui.test.onRoot
import org.junit.Rule
import ai.nuanu.slatrix.ui.account.LiveWorkspace
import ai.nuanu.slatrix.ui.account.WorkspaceCover
import ai.nuanu.slatrix.ui.designsystem.Motion
import android.provider.Settings
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Modern messenger spring physics, 1:1 predictive back with parallax, smooth exits, and reduced-motion respect. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class MotionTest {
    @get:Rule val compose = createComposeRule()

    @Test fun motionTokensExposeMessengerSpringPhysics() {
        val spatial = Motion.spatial<Float>()
        val snappy = Motion.snappy<Float>()
        val gentle = Motion.gentle<Float>()
        assertEquals(0.88f, spatial.dampingRatio, 0.001f)
        assertEquals(380f, spatial.stiffness, 0.1f)
        assertEquals(0.78f, snappy.dampingRatio, 0.001f)
        assertEquals(520f, snappy.stiffness, 0.1f)
        assertEquals(0.94f, gentle.dampingRatio, 0.001f)
        assertEquals(320f, gentle.stiffness, 0.1f)
        assertEquals(0.18f, Motion.PushParallax, 0.001f)
        assertEquals(0.22f, Motion.ScrimMaxAlpha, 0.001f)
        assertEquals(18L, Motion.ReactionStaggerMillis)
    }

    @Test fun aPushedPageSpringsInFromTheRightAndSettles() {
        var shown by mutableStateOf(false)
        compose.setContent {
            SlatrixTheme {
                LiveWorkspace(listOfNotNull(WorkspaceCover("preferences") { LivePreferencesScreen(false, null, false, {}, {}, {}) }.takeIf { shown })) {
                    Text("You")
                }
            }
        }
        settles("Color mode") { shown = true }
    }

    @Test fun aMessageMenuSpringsInAndSettles() {
        val message = ConversationMessage("a", "\$a", "@mira:example.org", "Mira", "Ship it", null, 1_700_000_000_000L,
            MessageKind.Text, MessageSendState.Sent, false, "M", 0)
        var shown by mutableStateOf(false)
        compose.setContent {
            SlatrixTheme { if (shown) MessageActionsHost(message, MessageActions(), null, {}, {}, {}) {} }
        }
        settles("Copy text") { shown = true }
    }

    @Test fun aConversationSlidesInWithParallaxAndGlidesBackSmoothlyOnPop() {
        var open by mutableStateOf(false)
        compose.setContent {
            SlatrixTheme {
                LiveWorkspace(listOfNotNull(WorkspaceCover("design") { Text("Conversation") }.takeIf { open })) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Home") }
                }
            }
        }
        compose.waitForIdle()
        val homeRest = bounds("Home").left
        settles("Conversation") { open = true }

        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { open = false; Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        val midPopHome = bounds("Home").left
        assertTrue("Home glides in from left parallax instead of cutting ($midPopHome vs $homeRest)", midPopHome < homeRest - 1f)
        compose.mainClock.advanceTimeBy(1_000)
        assertEquals("Home settles cleanly at rest", homeRest, bounds("Home").left, 1f)
    }

    @Test fun whileAConversationSlidesInWhatItCoversStaysUnderIt() {
        var open by mutableStateOf(false)
        compose.setContent {
            SlatrixTheme { LiveWorkspace(listOfNotNull(WorkspaceCover("design") { Text("Conversation") }.takeIf { open })) { Text("Home") } }
        }
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { open = true; Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Home").assertExists()
        compose.mainClock.advanceTimeBy(2_000)
        compose.onNodeWithText("Home").assertDoesNotExist()
    }

    // Pinned messages showed the conversation and its header for a moment, under a page fading in over nothing.
    @Test fun aPageFromChannelDetailsSlidesInOverTheDetails() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        compose.setContent { SlatrixTheme { ChannelDetailsScreen(room, null, ChannelDetailsActions(), {}, {}) {} } }
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        compose.onNodeWithText("Members").performSemanticsAction(SemanticsActions.OnClick)
        compose.runOnUiThread { Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Channel details").assertExists()
        compose.mainClock.advanceTimeBy(2_000)
        compose.onNodeWithText("Channel details").assertDoesNotExist()
    }

    @Test fun goingBackGlidesTheRevealedPageSmoothlyIntoPlace() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        compose.setContent { SlatrixTheme { ChannelDetailsScreen(room, null, ChannelDetailsActions(), {}, {}) {} } }
        compose.onNodeWithText("Members").performClick()
        compose.waitForIdle()
        // Every pushed page's title sits in the same place in its bar.
        val title = bounds("Members").left
        compose.mainClock.autoAdvance = false
        // As a semantics action, since a tap's own events need the clock this holds.
        compose.onNodeWithContentDescription("Back").performSemanticsAction(SemanticsActions.OnClick)
        compose.runOnUiThread { Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        val gliding = bounds("Channel details").left
        assertTrue("Details glide back from left parallax ($gliding vs $title)", gliding < title - 1f)
        compose.mainClock.advanceTimeBy(1_000)
        assertEquals("Details settle at the exact title rest position", title, bounds("Channel details").left, 1f)
    }

    // capability: app.predictive-back
    @Test fun aPageFollowsBackAsItsSwipedAndGoesOnlyOnRelease() {
        var went = false
        lateinit var dispatcher: OnBackPressedDispatcher
        compose.setContent {
            dispatcher = LocalOnBackPressedDispatcherOwner.current!!.onBackPressedDispatcher
            SlatrixTheme { LivePreferencesScreen(false, null, false, {}, {}, { went = true }) }
        }
        compose.waitForIdle()
        val rest = bounds("Color mode")
        compose.runOnUiThread {
            dispatcher.dispatchOnBackStarted(BackEventCompat(0f, 800f, 0f, BackEventCompat.EDGE_LEFT))
            dispatcher.dispatchOnBackProgressed(BackEventCompat(300f, 800f, 0.5f, BackEventCompat.EDGE_LEFT))
        }
        compose.waitForIdle()
        assertTrue("The page moves with the swipe", bounds("Color mode").left > rest.left)
        assertFalse("It stays until the swipe is let go", went)

        compose.runOnUiThread { dispatcher.dispatchOnBackCancelled() }
        compose.waitForIdle()
        assertEquals("A swipe taken back returns the page", rest, bounds("Color mode"))

        compose.runOnUiThread {
            dispatcher.dispatchOnBackStarted(BackEventCompat(0f, 800f, 0f, BackEventCompat.EDGE_LEFT))
            dispatcher.onBackPressed()
        }
        compose.runOnIdle { assertTrue(went) }
    }

    // A profile's back swipe faded it over the page under it and moved it only a quarter of the way.
    @Test fun aBackSwipeCarriesThePageWithTheFinger() {
        lateinit var dispatcher: OnBackPressedDispatcher
        compose.setContent {
            dispatcher = LocalOnBackPressedDispatcherOwner.current!!.onBackPressedDispatcher
            SlatrixTheme { LivePreferencesScreen(false, null, false, {}, {}, {}) }
        }
        compose.waitForIdle()
        val rest = bounds("Color mode")
        val width = compose.onRoot().fetchSemanticsNode().boundsInRoot.width
        compose.runOnUiThread {
            dispatcher.dispatchOnBackStarted(BackEventCompat(0f, 800f, 0f, BackEventCompat.EDGE_LEFT))
            dispatcher.dispatchOnBackProgressed(BackEventCompat(width / 2, 800f, 0.5f, BackEventCompat.EDGE_LEFT))
        }
        compose.waitForIdle()
        assertEquals("Halfway across, the page is halfway off", rest.left + width / 2, bounds("Color mode").left, 1f)
    }

    // capability: app.predictive-back
    @Test fun predictiveBackInWorkspaceDrivesTopPageAndParallaxesPageUnderneath() {
        var open by mutableStateOf(true)
        lateinit var dispatcher: OnBackPressedDispatcher
        compose.setContent {
            dispatcher = LocalOnBackPressedDispatcherOwner.current!!.onBackPressedDispatcher
            SlatrixTheme {
                LiveWorkspace(listOfNotNull(
                    WorkspaceCover("preferences") { LivePreferencesScreen(false, null, false, {}, {}, { open = false }) }.takeIf { open },
                )) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Home") }
                }
            }
        }
        compose.waitForIdle()
        val width = compose.onRoot().fetchSemanticsNode().boundsInRoot.width
        val topRest = bounds("Color mode").left

        compose.runOnUiThread {
            dispatcher.dispatchOnBackStarted(BackEventCompat(0f, 800f, 0f, BackEventCompat.EDGE_LEFT))
            dispatcher.dispatchOnBackProgressed(BackEventCompat(width / 2, 800f, 0.5f, BackEventCompat.EDGE_LEFT))
        }
        compose.waitForIdle()
        assertEquals("Top page follows finger 1:1", topRest + width / 2, bounds("Color mode").left, 2f)
        val homeHalf = bounds("Home").left

        compose.runOnUiThread {
            dispatcher.dispatchOnBackProgressed(BackEventCompat(width * 0.9f, 800f, 0.9f, BackEventCompat.EDGE_LEFT))
        }
        compose.waitForIdle()
        val homeNear = bounds("Home").left
        assertTrue("Underlying page glides right as back progresses ($homeHalf -> $homeNear)", homeNear > homeHalf + 10f)

        compose.runOnUiThread { dispatcher.dispatchOnBackCancelled() }
        compose.waitForIdle()
        assertEquals("Cancel springs top page back to rest", topRest, bounds("Color mode").left, 1f)
        compose.onNodeWithText("Home").assertDoesNotExist()
    }

    @Test fun reducedMotionSnapsWorkspaceTransitionsImmediately() {
        val resolver = ApplicationProvider.getApplicationContext<Application>().contentResolver
        val previous = Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
        Settings.Global.putFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        try {
            var open by mutableStateOf(false)
            compose.setContent {
                SlatrixTheme {
                    LiveWorkspace(listOfNotNull(WorkspaceCover("design") { Text("Conversation") }.takeIf { open })) {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Home") }
                    }
                }
            }
            compose.waitForIdle()
            val homeRest = bounds("Home").left
            compose.mainClock.autoAdvance = false
            compose.runOnUiThread { open = true; Snapshot.sendApplyNotifications() }
            compose.mainClock.advanceTimeByFrame()
            compose.mainClock.advanceTimeByFrame()
            val afterPush = bounds("Conversation").left
            compose.mainClock.advanceTimeBy(1_000)
            assertEquals("Push lands immediately under reduced motion", bounds("Conversation").left, afterPush, 1f)

            compose.runOnUiThread { open = false; Snapshot.sendApplyNotifications() }
            compose.mainClock.advanceTimeByFrame()
            compose.mainClock.advanceTimeByFrame()
            assertEquals("Pop lands immediately under reduced motion", homeRest, bounds("Home").left, 1f)
        } finally {
            Settings.Global.putFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, previous)
        }
    }

    @Test fun poppingAPageSlidesItOutWithoutRecreatingItsCompositionAndReopeningMidExitStartsFresh() {
        var open by mutableStateOf(true)
        var mounts = 0
        var lastMarker = ""
        var mutate: (() -> Unit)? = null
        compose.setContent {
            SlatrixTheme {
                LiveWorkspace(listOfNotNull(WorkspaceCover("design") {
                    androidx.compose.runtime.DisposableEffect(Unit) { mounts++; onDispose {} }
                    var marker by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf("fresh") }
                    mutate = { marker = "scrolled" }
                    lastMarker = marker
                    Text("Page: $marker")
                }.takeIf { open })) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Home") }
                }
            }
        }
        compose.waitForIdle()
        assertEquals(1, mounts)
        compose.runOnIdle { mutate?.invoke() }
        compose.waitForIdle()
        assertEquals("scrolled", lastMarker)

        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { open = false; Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        assertEquals("Popping must not dispose and recreate the exiting page mid-slide", 1, mounts)

        // Interrupt mid-exit by re-pushing the same key: must start fresh rather than inherit dying saved state.
        compose.runOnUiThread { open = true; Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeBy(1_000)
        assertEquals(2, mounts)
        assertEquals("fresh", lastMarker)
        compose.onNodeWithText("Page: fresh").assertExists()
    }

    @Test fun quickReactionsStaggerIntoTheMessageSheetAndLandAligned() {
        val message = ConversationMessage("a", "\$a", "@mira:example.org", "Mira", "Ship it", null, 1_700_000_000_000L,
            MessageKind.Text, MessageSendState.Sent, false, "M", 0)
        val quick = listOf("🎉", "👍", "🙂", "❤️", "💯")
        var shown by mutableStateOf(false)
        compose.setContent {
            SlatrixTheme {
                if (shown) MessageActionsHost(message, MessageActions(quick = quick, onReact = { _, _ -> }), null, {}, {}, {}) {}
            }
        }
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { shown = true; Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        // Querying mounts the Dialog's window; advancing 56ms then animates index 0 while index 4 (72ms delay) still waits.
        compose.onNodeWithText("🎉", useUnmergedTree = true).assertExists()
        compose.mainClock.advanceTimeBy(56)
        val firstEarly = compose.onNodeWithText("🎉", useUnmergedTree = true).getUnclippedBoundsInRoot().top.value
        val lastEarly = compose.onNodeWithText("💯", useUnmergedTree = true).getUnclippedBoundsInRoot().top.value
        assertTrue("Later quick reactions stagger in after the first ($firstEarly vs $lastEarly)", lastEarly > firstEarly + 0.5f)
        compose.mainClock.advanceTimeBy(800)
        val firstSettled = compose.onNodeWithText("🎉", useUnmergedTree = true).getUnclippedBoundsInRoot().top.value
        val lastSettled = compose.onNodeWithText("💯", useUnmergedTree = true).getUnclippedBoundsInRoot().top.value
        assertEquals("All quick reactions settle on one baseline", firstSettled, lastSettled, 0.5f)
    }

    @Test fun jumpToBottomFabAnimatesOutSmoothlyWhenReturningToNewest() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        val many = (1..80).map {
            ConversationMessage("m$it", "\$m$it", "@mira:example.org", "Mira", "Message $it", null,
                1_700_000_000_000L + it * 60_000L, MessageKind.Text, MessageSendState.Sent, false, "M", 0)
        }
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(many, loading = false, hasMore = false),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNode(hasScrollToIndexAction()).performScrollToIndex(40)
        compose.onNodeWithContentDescription("Jump to recent messages").assertExists()

        compose.mainClock.autoAdvance = false
        compose.onNode(hasScrollToIndexAction()).performScrollToIndex(0)
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        // Smooth exit animation keeps the FAB scaling/fading out across frames rather than cutting in 1 frame.
        compose.onNodeWithContentDescription("Jump to recent messages").assertExists()
        compose.mainClock.advanceTimeBy(800)
        compose.onNodeWithContentDescription("Jump to recent messages").assertDoesNotExist()
    }

    @Test fun dismissingMessageSheetUnblursAndFadesScrimSmoothlyInsteadOfSnapping() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        val msg = ConversationMessage("a", "\$a", "@mira:example.org", "Mira", "Ship it", null,
            1_700_000_000_000L, MessageKind.Text, MessageSendState.Sent, false, "M", 0)
        lateinit var view: View
        compose.setContent {
            view = LocalView.current
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(msg), loading = false, hasMore = false),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                    actions = MessageActions(quick = listOf("👍"), onReact = { _, _ -> }))
            }
        }
        fun topPixel(): Color {
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
            return Color(bitmap.getPixel(view.width / 2, view.height / 4))
        }
        compose.waitForIdle()
        val atRest = topPixel()

        compose.onNodeWithText("Ship it").performTouchInput { longClick() }
        compose.waitForIdle()
        val dimmed = topPixel()
        assertTrue("Opening message sheet dims the conversation behind it", abs(dimmed.red - atRest.red) > 0.05f)

        compose.mainClock.autoAdvance = false
        compose.onNodeWithText("Copy text").performSemanticsAction(SemanticsActions.OnClick)
        compose.runOnUiThread { Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        val midDismiss = topPixel()
        assertTrue("Dismissing fades the scrim smoothly instead of snapping to rest ($midDismiss vs $atRest)",
            abs(midDismiss.red - atRest.red) > 0.02f)

        compose.mainClock.advanceTimeBy(1_000)
        val restored = topPixel()
        assertTrue("Conversation returns to rest after smooth exit ($restored vs $atRest)",
            abs(restored.red - atRest.red) < 0.02f)
    }

    @Test fun bottomSheetSlidesDownSmoothlyOnDismissBeforeClosing() {
        var open by mutableStateOf(true)
        var dismissed = false
        compose.setContent {
            SlatrixTheme {
                if (open) BottomSheet({ dismissed = true; open = false }, SlatrixTheme.colors.overlay) {
                    Text("Sheet item")
                }
            }
        }
        compose.waitForIdle()
        val restTop = compose.onNodeWithText("Sheet item").getUnclippedBoundsInRoot().top.value
        compose.mainClock.autoAdvance = false
        compose.onNodeWithContentDescription("Close").performSemanticsAction(SemanticsActions.OnClick)
        compose.runOnUiThread { Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeBy(48)
        assertFalse("Sheet animates down before calling onDismissRequest", dismissed)
        val slidingTop = compose.onNodeWithText("Sheet item").getUnclippedBoundsInRoot().top.value
        assertTrue("Sheet moves downward while dismissing ($slidingTop vs $restTop)", slidingTop > restTop + 1f)
        compose.mainClock.advanceTimeBy(1_000)
        assertTrue("Sheet finishes dismissing once off-screen", dismissed)
        compose.onNodeWithText("Sheet item").assertDoesNotExist()
    }

    @Test fun mediaViewerSwipeDownDismissesWhenUnzoomedAndSpringsBackWhenShort() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        val png = ByteArrayOutputStream().also { Bitmap.createBitmap(16, 9, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        val photo = ConversationMessage("p", "\$p", "@mira:example.org", "Mira", "office.jpg", null,
            1_700_000_000_000L, MessageKind.Attachment, MessageSendState.Sent, false, "M", 0,
            attachment = MessageAttachment(MessageAttachment.Kind.Image, "office.jpg", "image/jpeg", 2_000_000, 1600, 900, TestMediaSource("mxc://example.org/swipe")))
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(photo), loading = false, hasMore = false),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                    loadPicture = { _, _, _, _ -> png })
            }
        }
        compose.onNodeWithContentDescription("office.jpg").performClick()
        val viewer = hasContentDescription("office.jpg") and hasAnyAncestor(isDialog())
        compose.onNode(viewer).assertIsDisplayed()

        // A short downward nudge below threshold springs back without dismissing.
        compose.onNode(viewer).performTouchInput { swipeDown(startY = centerY, endY = centerY + 40f, durationMillis = 300) }
        compose.onNodeWithContentDescription("Close").assertIsDisplayed()

        // While zoomed in, a vertical drag pans rather than dismissing.
        compose.onNode(viewer).performTouchInput { doubleClick() }
        compose.onNode(viewer).performTouchInput { swipeDown(startY = top + 100f, endY = bottom - 100f, durationMillis = 300) }
        compose.onNodeWithContentDescription("Close").assertIsDisplayed()

        // Unzoom back to 1x, then a full vertical swipe dismisses the viewer.
        compose.onNode(viewer).performTouchInput { doubleClick() }
        compose.onNode(viewer).performTouchInput { swipeDown(startY = top + 100f, endY = bottom - 50f, durationMillis = 200) }
        compose.onNodeWithContentDescription("Close").assertDoesNotExist()
    }

    @Test fun composerBannerAnimatesHeightAndSendButtonKeepsSemantics() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        var composer by mutableStateOf(ComposerState(loading = false))
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(emptyList(), loading = false, hasMore = false),
                    composer, {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNodeWithText("Message #design").performClick()
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Send message").assertIsNotEnabled()

        compose.mainClock.autoAdvance = false
        compose.runOnUiThread {
            composer = composer.copy(
                text = "Sounds good",
                target = ComposerTarget.Reply("\$p", "Mira", "Ship it?"),
            )
            Snapshot.sendApplyNotifications()
        }
        compose.mainClock.advanceTimeBy(32)
        val midTop = compose.onNodeWithText("Replying to Mira").getUnclippedBoundsInRoot().top.value
        compose.mainClock.advanceTimeBy(800)
        val settledTop = compose.onNodeWithText("Replying to Mira").getUnclippedBoundsInRoot().top.value
        assertTrue("Reply banner animates the composer upward smoothly instead of snapping ($midTop vs $settledTop)",
            midTop > settledTop + 1f)
        compose.onNodeWithContentDescription("Send message").assertIsEnabled()
    }

    @Test fun jumpHighlightFadesOutSmoothlyAfterHoldInsteadOfSnapping() {
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
        val rows = (1..20).map { i ->
            ConversationMessage("m$i", "\$m$i", "@mira:example.org", "Mira", "Message $i", null,
                1_700_000_000_000L + i * 60_000L, MessageKind.Text, MessageSendState.Sent, false, "M", 0)
        }
        lateinit var rootView: View
        fun rowEdgePixel(bounds: Rect): Color {
            val bitmap = Bitmap.createBitmap(rootView.width, rootView.height, Bitmap.Config.ARGB_8888)
            rootView.draw(Canvas(bitmap))
            val x = (bounds.left + 8f).toInt().coerceIn(0, bitmap.width - 1)
            val y = bounds.center.y.toInt().coerceIn(0, bitmap.height - 1)
            return Color(bitmap.getPixel(x, y))
        }
        compose.mainClock.autoAdvance = false
        compose.setContent {
            rootView = LocalView.current
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(rows, loading = false, hasMore = false, highlight = "\$m10"),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        compose.mainClock.advanceTimeBy(160)
        val targetBounds = compose.onNodeWithText("Message 10").fetchSemanticsNode().boundsInRoot
        val fullLit = rowEdgePixel(targetBounds)

        // Just past the hold duration, the highlight wash is fading smoothly rather than snapping off.
        compose.mainClock.advanceTimeBy(UiMetrics.HighlightMillis - 160 + 48)
        val midFade = rowEdgePixel(targetBounds)

        compose.mainClock.advanceTimeBy(1_000)
        val cleared = rowEdgePixel(targetBounds)

        assertTrue("Jump highlight visibly tints the target row ($fullLit vs $cleared)",
            abs(fullLit.blue - cleared.blue) > 0.04f)
        assertTrue("Jump highlight fades smoothly after hold instead of snapping ($midFade between $fullLit and $cleared)",
            abs(midFade.blue - cleared.blue) > 0.01f && abs(midFade.blue - fullLit.blue) > 0.01f)
    }

    /** After [show], [text] is still on its way in two frames later, and settles cleanly within 600 ms. */
    private fun settles(text: String, show: () -> Unit) {
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { show(); Snapshot.sendApplyNotifications() }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        val early = bounds(text)
        compose.mainClock.advanceTimeBy(600)
        val settled = bounds(text)
        compose.mainClock.advanceTimeBy(2_000)
        assertNotEquals("It springs in rather than appearing in place", settled, early)
        assertEquals("It has settled cleanly", settled, bounds(text))
    }

    private fun bounds(text: String): Rect = compose.onNodeWithText(text).fetchSemanticsNode().boundsInRoot
}
