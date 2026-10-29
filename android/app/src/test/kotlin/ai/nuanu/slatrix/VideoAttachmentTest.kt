package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageAttachment
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.MediaSource
import org.matrix.rustcomponents.sdk.NoHandle
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class VideoAttachmentTest {
    @get:Rule val compose = createComposeRule()
    private val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
    private val source = object : MediaSource(NoHandle) { override fun url(): String = "mxc://example.org/clip" }
    private val clip = MessageAttachment(MessageAttachment.Kind.Video, "clip.mp4", "video/mp4", 5_000_000, 1280, 720, source,
        durationMillis = 83_000)
    private val requested = mutableListOf<MessageAttachment>()
    private val file = CompletableDeferred<File?>()

    // capability: message.video
    // capability: message.media-viewer
    @Test fun aVideoKeepsItsShapeAndLengthPlaysInPlaceAndOpensFullScreen() {
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(ConversationMessage("v", "\$v", "@mira:example.org", "Mira", "clip.mp4",
                    null, 1_700_000_000_000L, MessageKind.Attachment, MessageSendState.Sent, false, "M", 0, attachment = clip)),
                    loading = false, hasMore = false), ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                    loadFile = { requested += it; file.await() })
            }
        }
        compose.onNodeWithText("1:23", useUnmergedTree = true).assertIsDisplayed()
        val poster = compose.onNodeWithContentDescription("clip.mp4").fetchSemanticsNode().boundsInRoot
        assertEquals("The box keeps the video's shape", 720f / 1280f, poster.height / poster.width, 0.01f)

        compose.onNodeWithContentDescription("clip.mp4").performClick()
        compose.runOnIdle { assertEquals(listOf(clip), requested) }
        file.complete(File.createTempFile("clip", ".mp4"))
        compose.waitForIdle()
        assertEquals("Playing never moves the row", poster, compose.onNodeWithContentDescription("clip.mp4").fetchSemanticsNode().boundsInRoot)

        compose.onNodeWithContentDescription("clip.mp4").performClick()
        compose.onNodeWithContentDescription("Close").assertIsDisplayed().performClick()
        compose.onNodeWithContentDescription("Close").assertDoesNotExist()
    }
}
