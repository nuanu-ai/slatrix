package ai.nuanu.slatrix

import android.graphics.Rect
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MatrixComposer
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.compose.setContent
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.lifecycle.lifecycleScope
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.ComposerDraft
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.Room

@RunWith(AndroidJUnit4::class)
class ComposerInputTest {
    @Test fun rapidKeyboardInputSurvivesDraftStateUpdates() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val expected = "Slatrix Android check 2026-10-29 A1"
        val loaded = CountDownLatch(1)
        val typed = CountDownLatch(1)
        lateinit var composer: MatrixComposer
        val room = object : Room(NoHandle) {
            override suspend fun loadComposerDraft(threadRoot: String?): ComposerDraft? = null
            override suspend fun saveComposerDraft(draft: ComposerDraft, threadRoot: String?) {
                withContext(Dispatchers.IO) { draft.plainText.toByteArray() }
            }
            override suspend fun clearComposerDraft(threadRoot: String?) = Unit
        }
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                composer = MatrixComposer(activity.lifecycleScope, room) { false }
                activity.lifecycleScope.launch {
                    composer.state.first { !it.loading }
                    loaded.countDown()
                    composer.state.first { it.text == expected }
                    typed.countDown()
                }
                activity.setContent {
                    SlatrixTheme {
                        val state by composer.state.collectAsState()
                        LiveChannelScreen(RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0),
                            ConversationState(loading = false, hasMore = false), state, composer::edit, composer::send,
                            {}, {}, {}, composer::retry, {}, {})
                    }
                }
            }
            assertTrue("Draft never became editable", loaded.await(5, TimeUnit.SECONDS))
            instrumentation.waitForIdleSync()
            val automation = instrumentation.uiAutomation
            fun field(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
                if (node == null) return null
                if (node.contentDescription?.toString() == "Message #design") return node
                for (index in 0 until node.childCount) field(node.getChild(index))?.let { return it }
                return null
            }
            // The app builds its accessibility tree only after it hears UiAutomation turned accessibility on, and no
            // event announces the tree, so ask for it until the field is in it.
            val deadline = SystemClock.uptimeMillis() + 10_000
            var found = field(automation.rootInActiveWindow)
            while (found == null && SystemClock.uptimeMillis() < deadline) {
                automation.waitForIdle(100, 1_000)
                found = field(automation.rootInActiveWindow)
            }
            val input = requireNotNull(found) { "Composer input is missing; the active window is ${automation.rootInActiveWindow?.packageName}" }
            val bounds = Rect().also(input::getBoundsInScreen)
            val time = SystemClock.uptimeMillis()
            listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP).forEach { action ->
                val event = MotionEvent.obtain(time, time, action, bounds.exactCenterX(), bounds.exactCenterY(), 0)
                event.source = InputDevice.SOURCE_TOUCHSCREEN
                try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
            }
            instrumentation.waitForIdleSync()
            ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand("input text ${expected.replace(" ", "%s")}")).use { it.readBytes() }
            assertTrue("Keyboard input was truncated: ${composer.state.value.text}", typed.await(5, TimeUnit.SECONDS))
            assertEquals(expected, composer.state.value.text)
            runBlocking { composer.close() }
        }
        room.close()
    }
}
