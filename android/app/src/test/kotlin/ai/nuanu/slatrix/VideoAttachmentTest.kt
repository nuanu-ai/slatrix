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
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.semantics.SemanticsActions
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
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class VideoAttachmentTest {
    @get:Rule val compose = createComposeRule()
    private val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
    private val source = TestMediaSource("mxc://example.org/clip")
    private val clip = MessageAttachment(MessageAttachment.Kind.Video, "clip.mp4", "video/mp4", 5_000_000, 1280, 720, source,
        durationMillis = 83_000)
    private val requested = mutableListOf<MessageAttachment>()
    private val file = CompletableDeferred<File?>()

    // capability: message.video
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
        file.complete(playableTestMedia("clip"))
        compose.waitForIdle()
        assertEquals("Playing never moves the row", poster, compose.onNodeWithContentDescription("clip.mp4").fetchSemanticsNode().boundsInRoot)

        compose.onNodeWithContentDescription("clip.mp4").performClick()
        compose.onNodeWithContentDescription("Close").assertIsDisplayed()
        compose.onNodeWithContentDescription("Share").assertIsDisplayed()
        compose.onNodeWithContentDescription("Save to device").assertIsDisplayed()
        compose.onNodeWithContentDescription("Close").performClick()
        compose.onNodeWithContentDescription("Close").assertDoesNotExist()
    }

    @Test fun failedVideoDownloadClearsFetchingAndDeduplicatesTaps() {
        var calls = 0
        val firstAttempt = CompletableDeferred<File?>()
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(ConversationMessage("v", "\$v", "@mira:example.org", "Mira", "clip.mp4",
                    null, 1_700_000_000_000L, MessageKind.Attachment, MessageSendState.Sent, false, "M", 0, attachment = clip)),
                    loading = false, hasMore = false), ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                    loadFile = {
                        calls += 1
                        if (calls == 1) firstAttempt.await() else playableTestMedia("retry")
                    })
            }
        }
        compose.onNodeWithContentDescription("clip.mp4").performClick()
        compose.onNodeWithContentDescription("clip.mp4").performClick()
        compose.runOnIdle { assertEquals("Second tap while downloading must not start a duplicate fetch", 1, calls) }
        firstAttempt.complete(null)
        compose.waitForIdle()
        compose.onNodeWithContentDescription("clip.mp4").performClick()
        compose.waitForIdle()
        compose.onNode(hasContentDescription("clip.mp4") and hasOnClickLabel("Full screen")).assertExists()
        assertEquals(2, calls)
    }

    @Test fun unplayableVideoShowsErrorAndResetsToPoster() {
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(ConversationMessage("v", "\$v", "@mira:example.org", "Mira", "clip.mp4",
                    null, 1_700_000_000_000L, MessageKind.Attachment, MessageSendState.Sent, false, "M", 0, attachment = clip)),
                    loading = false, hasMore = false), ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                    loadFile = { File.createTempFile("broken", ".mp4") })
            }
        }
        compose.onNodeWithContentDescription("clip.mp4").performClick()
        compose.waitUntil(timeoutMillis = 3_000) {
            compose.onAllNodes(hasContentDescription("clip.mp4") and hasOnClickLabel("Play video")).fetchSemanticsNodes().size == 1 &&
                compose.onAllNodes(androidx.compose.ui.test.hasText("Couldn’t play this media."), useUnmergedTree = true)
                    .fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText("Couldn’t play this media.", useUnmergedTree = true).assertIsDisplayed()
    }

    @Test fun audioAttachmentShowsDurationAndPlayButtonAndDownloadsOnTap() {
        val voice = MessageAttachment(
            MessageAttachment.Kind.Audio, "voice.ogg", "audio/ogg", 24_000, null, null,
            TestMediaSource("mxc://example.org/voice"), durationMillis = 15_000,
            waveform = listOf(120, 600, 900, 300), isVoice = true,
        )
        val asked = mutableListOf<MessageAttachment>()
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(ConversationMessage("a", "\$a", "@mira:example.org", "Mira", "voice.ogg",
                    null, 1_700_000_000_000L, MessageKind.Attachment, MessageSendState.Sent, false, "M", 0, attachment = voice)),
                    loading = false, hasMore = false), ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                    loadFile = { asked += it; null })
            }
        }
        compose.onNodeWithText("0:15", substring = true, useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithContentDescription("Play audio", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("Voice message", useUnmergedTree = true).assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(listOf(voice), asked) }
    }

    @Test fun playingAnotherVideoStopsTheFirst() {
        val other = clip.copy(name = "other.mp4", source = TestMediaSource("mxc://example.org/other"))
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(clip to "v", other to "w").map { (attachment, id) ->
                    ConversationMessage(id, "\$$id", "@mira:example.org", "Mira", attachment.name, null, 1_700_000_000_000L,
                        MessageKind.Attachment, MessageSendState.Sent, false, "M", 0, attachment = attachment, grouped = id == "w")
                }, loading = false, hasMore = false), ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                    loadFile = { playableTestMedia(it.name.substringBefore('.')) })
            }
        }
        compose.onNodeWithContentDescription("clip.mp4").performClick()
        compose.onNode(hasContentDescription("clip.mp4") and hasClickAction() and hasOnClickLabel("Full screen")).assertExists()
        compose.onNodeWithContentDescription("other.mp4").performClick()
        compose.onNode(hasContentDescription("other.mp4") and hasOnClickLabel("Full screen")).assertExists()
        compose.onNode(hasContentDescription("clip.mp4") and hasOnClickLabel("Play video")).assertExists()
    }

    @Test fun slowEarlierDownloadDoesNotTakeOverNewerClip() {
        val other = clip.copy(name = "other.mp4", source = TestMediaSource("mxc://example.org/other"))
        val slowFirst = CompletableDeferred<File?>()
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(clip to "v", other to "w").map { (attachment, id) ->
                    ConversationMessage(id, "\$$id", "@mira:example.org", "Mira", attachment.name, null, 1_700_000_000_000L,
                        MessageKind.Attachment, MessageSendState.Sent, false, "M", 0, attachment = attachment, grouped = id == "w")
                }, loading = false, hasMore = false), ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                    loadFile = { if (it.name == "clip.mp4") slowFirst.await() else playableTestMedia("other") })
            }
        }
        compose.onNodeWithContentDescription("clip.mp4").performClick()
        compose.onNodeWithContentDescription("other.mp4").performClick()
        compose.onNode(hasContentDescription("other.mp4") and hasOnClickLabel("Full screen")).assertExists()
        // Now the earlier clip's slow download finishes: it must NOT steal playback from other.mp4.
        slowFirst.complete(playableTestMedia("clip"))
        compose.waitForIdle()
        compose.onNode(hasContentDescription("other.mp4") and hasOnClickLabel("Full screen")).assertExists()
        compose.onNode(hasContentDescription("clip.mp4") and hasOnClickLabel("Play video")).assertExists()
    }

    @Test fun audioErrorExposesExplicitOpenInAnotherAppActionWithoutHijackingPlay() {
        val voice = MessageAttachment(
            MessageAttachment.Kind.Audio, "voice.ogg", "audio/ogg", 24_000, null, null,
            TestMediaSource("mxc://example.org/broken-voice"), durationMillis = 15_000, isVoice = true,
        )
        var openedExternally = 0
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(ConversationMessage("a", "\$a", "@mira:example.org", "Mira", "voice.ogg",
                    null, 1_700_000_000_000L, MessageKind.Attachment, MessageSendState.Sent, false, "M", 0, attachment = voice)),
                    loading = false, hasMore = false), ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                    onOpenFile = { openedExternally += 1; null },
                    loadFile = { null })
            }
        }
        compose.onNodeWithText("Voice message", useUnmergedTree = true).performClick()
        compose.onNodeWithText("Open in another app", useUnmergedTree = true).assertIsDisplayed()
        // Tapping Play/Voice message again must retry in-place, never silently hand off to an external app.
        compose.onNodeWithText("Voice message", useUnmergedTree = true).performClick()
        compose.runOnIdle { assertEquals(0, openedExternally) }
        compose.onNodeWithText("Open in another app", useUnmergedTree = true).performClick()
        compose.runOnIdle { assertEquals(1, openedExternally) }
    }
}

/** Minimal valid PCM WAV that ExoPlayer's pure-Java WavExtractor parses cleanly under Robolectric without MediaCodec. */
private fun playableTestMedia(prefix: String): File {
    val pcmBytes = 1_600
    val totalSize = 36 + pcmBytes
    val header = byteArrayOf(
        'R'.code.toByte(), 'I'.code.toByte(), 'F'.code.toByte(), 'F'.code.toByte(),
        (totalSize and 0xff).toByte(), ((totalSize shr 8) and 0xff).toByte(), 0, 0,
        'W'.code.toByte(), 'A'.code.toByte(), 'V'.code.toByte(), 'E'.code.toByte(),
        'f'.code.toByte(), 'm'.code.toByte(), 't'.code.toByte(), ' '.code.toByte(),
        16, 0, 0, 0, 1, 0, 1, 0,
        0x40, 0x1f, 0, 0, // 8000 Hz
        0x80.toByte(), 0x3e, 0, 0, // 16000 bytes/sec
        2, 0, 16, 0,
        'd'.code.toByte(), 'a'.code.toByte(), 't'.code.toByte(), 'a'.code.toByte(),
        (pcmBytes and 0xff).toByte(), ((pcmBytes shr 8) and 0xff).toByte(), 0, 0,
    )
    return File.createTempFile(prefix, ".wav").apply {
        writeBytes(header + ByteArray(pcmBytes))
    }
}

private fun hasOnClickLabel(label: String) =
    SemanticsMatcher("OnClick labelled $label") { it.config.getOrElseNullable(SemanticsActions.OnClick) { null }?.label == label }
