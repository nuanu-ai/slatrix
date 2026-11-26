package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.MessageAttachment
import ai.nuanu.slatrix.ui.account.MediaViewer
import ai.nuanu.slatrix.ui.account.ViewerMediaItem
import ai.nuanu.slatrix.ui.account.ViewerZoom
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import android.graphics.Bitmap
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.unit.IntSize
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
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
class MediaViewerWave3Test {
    @get:Rule val compose = createComposeRule()

    @Test fun viewerZoomClampsToFittedImageBoundsAndPivotsAroundFocalPoint() {
        // Portrait 100x400 image fitted into a 400x400 viewport has fitted size 100x400.
        // At 2x zoom, image width is 200 (still <= viewport width 400), so horizontal pan must clamp to 0!
        val clamped = ViewerZoom.clamp(
            offset = Offset(150f, 300f),
            scale = 2f,
            viewport = IntSize(400, 400),
            contentAspect = 100f / 400f,
        )
        assertEquals(0f, clamped.x, 0.5f)
        assertEquals(200f, clamped.y, 0.5f)

        // Double-tapping right of center shifts offset left so the tapped point stays under the finger.
        val (zoomedScale, zoomedOffset) = ViewerZoom.doubleTap(
            currentScale = 1f,
            tap = Offset(300f, 200f),
            viewport = IntSize(400, 400),
            contentAspect = 1f,
            targetScale = 2.5f,
        )
        assertEquals(2.5f, zoomedScale, 0.01f)
        assertTrue("Zooming into right side shifts image left", zoomedOffset.x < 0f)
    }

    // capability: message.media-viewer
    @Test fun mediaViewerSwipesBetweenItemsAndShowsCaptionAndForward() {
        val png = ByteArrayOutputStream().apply {
            Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.PNG, 100, this)
        }.toByteArray()
        val first = ViewerMediaItem(
            id = "m1",
            attachment = MessageAttachment(
                MessageAttachment.Kind.Image, "first.png", "image/png", 100, 800, 600,
                TestMediaSource("mxc://example.org/1"),
            ),
            sender = "Mira",
            timestamp = 1_700_000_000_000L,
            caption = "First shot",
        )
        val second = ViewerMediaItem(
            id = "m2",
            attachment = MessageAttachment(
                MessageAttachment.Kind.Image, "second.png", "image/png", 100, 800, 600,
                TestMediaSource("mxc://example.org/2"),
            ),
            sender = "Sam",
            timestamp = 1_700_000_060_000L,
            caption = "Second shot caption",
        )
        var forwarded: String? = null
        val pageChanges = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                MediaViewer(
                    items = listOf(first, second),
                    initialIndex = 0,
                    tile = 100 to 100,
                    load = { _, _, _, _ -> png },
                    loadFile = null,
                    onForward = { forwarded = it.id },
                    onPageChanged = { pageChanges += it },
                    onDismiss = {},
                )
            }
        }
        compose.onNodeWithText("Mira").assertIsDisplayed()
        compose.onNodeWithText("First shot").assertIsDisplayed()
        compose.onNodeWithContentDescription("first.png").performTouchInput { swipeLeft() }
        compose.waitForIdle()
        compose.onNodeWithText("Sam").assertIsDisplayed()
        compose.onNodeWithText("Second shot caption").assertIsDisplayed()
        compose.onNodeWithContentDescription("Forward").assertIsDisplayed().performClick()
        compose.runOnIdle {
            assertEquals("m2", forwarded)
            assertEquals(listOf("m2"), pageChanges)
        }
    }
}
