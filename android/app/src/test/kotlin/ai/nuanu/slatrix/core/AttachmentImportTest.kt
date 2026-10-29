package ai.nuanu.slatrix.core

import android.app.Application
import android.graphics.Bitmap
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35])
class AttachmentImportTest {
    private val context = ApplicationProvider.getApplicationContext<Application>()

    // capability: composer.attachments
    @Test fun aPickedImageIsCopiedForTheUploadWithItsNameTypeAndSize() = runTest {
        val picked = File(context.filesDir, "Beach day.png")
        picked.outputStream().use { Bitmap.createBitmap(30, 20, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.PNG, 100, it) }
        val attachment = AttachmentImport(context).prepare(Uri.fromFile(picked))
        assertEquals("Beach day.png", attachment.name)
        assertEquals("image/png", attachment.mimeType)
        assertEquals(30 to 20, attachment.width to attachment.height)
        assertEquals(picked.length(), attachment.size)
        assertNotEquals(picked.path, attachment.path)
        assertTrue(File(attachment.path).readBytes().contentEquals(picked.readBytes()))
    }
}
