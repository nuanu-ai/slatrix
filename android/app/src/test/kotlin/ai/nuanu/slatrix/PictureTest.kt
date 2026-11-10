package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.MessageAttachment
import ai.nuanu.slatrix.ui.account.LocalPictures
import ai.nuanu.slatrix.ui.account.SessionPictures
import ai.nuanu.slatrix.ui.account.picture
import android.app.Application
import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import java.io.ByteArrayOutputStream
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
@Config(application = Application::class, sdk = [35])
class PictureTest {
    @get:Rule val compose = createComposeRule()
    private class Source(private val revision: String) : MediaSource(NoHandle) {
        override fun url() = "mxc://example.org/private"
        override fun toJson() = "{\"url\":\"${url()}\",\"key\":\"$revision\"}"
    }
    private val attachment = MessageAttachment(MessageAttachment.Kind.Image, "photo.png", "image/png", 1024, 16, 16, Source("first"))
    private fun png() = ByteArrayOutputStream().also { out ->
        Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.PNG, 100, out)
    }.toByteArray()
    private fun displayed() = compose.onAllNodesWithContentDescription("Private picture").fetchSemanticsNodes().size

    // capability: message.image
    @Test fun aDifferentSessionLoadsItsOwnImageForTheSameMediaUrl() {
        val session = mutableStateOf(SessionPictures())
        val first = session.value
        val requested = CompletableDeferred<Unit>()
        compose.setContent {
            CompositionLocalProvider(LocalPictures provides session.value) {
                val owner = session.value
                picture(attachment, 16, 16, false) { _, _, _, _ ->
                    if (owner === first) png() else { requested.complete(Unit); null }
                }?.let { Image(it, "Private picture") }
            }
        }
        compose.waitUntil { displayed() == 1 }
        compose.runOnIdle { session.value = SessionPictures() }
        compose.waitForIdle()
        compose.waitUntil { requested.isCompleted }
        assertEquals("Denied in the new session, so the old decoded image must disappear", 0, displayed())
    }

    // capability: message.image
    @Test fun aNewEncryptionKeyCannotReuseTheOldDecryption() = changedSource(false)

    // capability: message.image
    @Test fun aNewThumbnailCannotReuseTheOldPreview() = changedSource(true)

    private fun changedSource(thumbnail: Boolean) {
        val current = mutableStateOf(if (thumbnail) attachment.copy(thumbnail = Source("first")) else attachment)
        val first = current.value
        val requested = CompletableDeferred<Unit>()
        compose.setContent {
            val item = current.value
            picture(item, 16, 16, false) { _, _, _, _ ->
                if (item === first) png() else { requested.complete(Unit); null }
            }?.let { Image(it, "Private picture") }
        }
        compose.waitUntil { displayed() == 1 }
        compose.runOnIdle {
            current.value = if (thumbnail) first.copy(thumbnail = Source("second")) else first.copy(source = Source("second"))
        }
        compose.waitForIdle()
        compose.waitUntil { requested.isCompleted }
        assertEquals(0, displayed())
    }
}
