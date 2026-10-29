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
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35])
class AttachmentImportTest {
    private val context = ApplicationProvider.getApplicationContext<Application>()

    @Test fun aNameFromTheProviderCantReachOutsideTheUploadFolder() = runTest {
        Robolectric.setupContentProvider(NamingProvider::class.java, "picker.test")
        val attachment = AttachmentImport(context).prepare(Uri.parse("content://picker.test/1"))
        val folder = File(context.cacheDir, "attachments").canonicalFile
        assertEquals("evil.xml", File(attachment.path).name)
        assertTrue(File(attachment.path).canonicalPath.startsWith(folder.path + File.separator))
    }

    @Test fun aFileThatCantBeReadLeavesNothingBehind() = runTest {
        val missing = Uri.fromFile(File(context.filesDir, "gone.png"))
        assertTrue(runCatching { AttachmentImport(context).prepare(missing) }.isFailure)
        assertEquals(emptyList<String>(), File(context.cacheDir, "attachments").list().orEmpty().toList())
    }

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

/** A picker that names its file with a path, as a hostile app could. */
class NamingProvider : android.content.ContentProvider() {
    override fun onCreate() = true
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, order: String?) =
        android.database.MatrixCursor(arrayOf(android.provider.OpenableColumns.DISPLAY_NAME)).apply { addRow(arrayOf("../../shared_prefs/evil.xml")) }
    override fun getType(uri: Uri) = "text/xml"
    override fun openFile(uri: Uri, mode: String): android.os.ParcelFileDescriptor {
        val file = File(context!!.filesDir, "provided").apply { writeText("<x/>") }
        return android.os.ParcelFileDescriptor.open(file, android.os.ParcelFileDescriptor.MODE_READ_ONLY)
    }
    override fun insert(uri: Uri, values: android.content.ContentValues?) = null
    override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = 0
    override fun update(uri: Uri, values: android.content.ContentValues?, selection: String?, args: Array<out String>?) = 0
}
