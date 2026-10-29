package ai.nuanu.slatrix.core

import android.app.Application
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
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
import org.robolectric.shadows.ShadowMediaMetadataRetriever
import org.robolectric.shadows.util.DataSource

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

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35])
class VideoImportTest {
    private val context = ApplicationProvider.getApplicationContext<Application>()

    // capability: composer.video
    @Test fun aPickedVideoGetsAnUprightPosterFromASecondInBesideItsCopy() = runTest {
        val picked = File(context.filesDir, "IMG_0042.MOV").apply { writeBytes(ByteArray(2_048)) }
        val uri = Uri.fromFile(picked)
        val source = DataSource.toDataSource(context, uri)
        ShadowMediaMetadataRetriever.addMetadata(source, MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH, "1920")
        ShadowMediaMetadataRetriever.addMetadata(source, MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT, "1080")
        ShadowMediaMetadataRetriever.addMetadata(source, MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION, "90")
        ShadowMediaMetadataRetriever.addMetadata(source, MediaMetadataRetriever.METADATA_KEY_DURATION, "4000")
        // The frame as the track stores it, on its side: what is up in the video is its left half.
        val sideways = Bitmap.createBitmap(1920, 1080, Bitmap.Config.ARGB_8888).apply {
            android.graphics.Canvas(this).apply {
                drawRect(0f, 0f, 960f, 1080f, android.graphics.Paint().apply { color = android.graphics.Color.RED })
                drawRect(960f, 0f, 1920f, 1080f, android.graphics.Paint().apply { color = android.graphics.Color.BLUE })
            }
        }
        ShadowMediaMetadataRetriever.addFrame(context, uri, 1_000_000L, sideways)

        val video = AttachmentImport(context).prepare(uri)
        assertEquals(1080 to 1920, video.width to video.height)
        assertEquals(4_000L, video.durationMillis)
        val poster = checkNotNull(video.poster)
        val file = File(poster.path)
        assertEquals("The poster goes up from the video's folder, which is cleared after", File(video.path).parentFile, file.parentFile)
        val drawn = BitmapFactory.decodeFile(file.path)
        assertEquals(450 to 800, drawn.width to drawn.height)
        fun reddish(x: Int, y: Int) = drawn.getPixel(x, y).let { android.graphics.Color.red(it) > android.graphics.Color.blue(it) }
        assertTrue("Turned upright, not stretched: the left half is now on top", reddish(225, 100) && !reddish(225, 700))
        assertEquals(450 to 800, poster.width to poster.height)
        assertEquals(file.length(), poster.size)
    }

    @Test fun aVideoWithoutAFrameToReadGoesWithoutAPoster() = runTest {
        val picked = File(context.filesDir, "odd.mp4").apply { writeBytes(ByteArray(512)) }
        val source = DataSource.toDataSource(context, Uri.fromFile(picked))
        ShadowMediaMetadataRetriever.addMetadata(source, MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH, "640")
        ShadowMediaMetadataRetriever.addMetadata(source, MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT, "360")
        val video = AttachmentImport(context).prepare(Uri.fromFile(picked))
        assertEquals(640 to 360, video.width to video.height)
        assertEquals(null, video.poster)
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
