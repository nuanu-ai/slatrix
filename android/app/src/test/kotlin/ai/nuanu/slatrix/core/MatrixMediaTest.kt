package ai.nuanu.slatrix.core

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.MediaFileHandle
import org.matrix.rustcomponents.sdk.MediaSource
import org.matrix.rustcomponents.sdk.NoHandle

class MatrixMediaTest {
    private class Source(private val url: String) : MediaSource(NoHandle) {
        override fun url(): String = url
    }

    private class MediaClient(private val download: File) : Client(NoHandle) {
        override suspend fun getMediaThumbnail(mediaSource: MediaSource, width: ULong, height: ULong): ByteArray =
            mediaSource.url().toByteArray()
        override suspend fun getMediaFile(mediaSource: MediaSource, filename: String?, mimeType: String, useCache: Boolean,
            tempDir: String?): MediaFileHandle = object : MediaFileHandle(NoHandle) {
            override fun path(): String = download.path
        }
    }

    private val original = Source("mxc://example.org/original")
    private fun image(size: Long?, thumbnail: MediaSource? = null) =
        MessageAttachment(MessageAttachment.Kind.Image, "photo.jpg", "image/jpeg", size, 1600, 900, original, thumbnail)

    // capability: message.image
    @Test fun aPictureComesFromTheSendersThumbnailOrASmallOriginalAndNeverFromAHugeOne() = runTest {
        val media = MatrixMedia(MediaClient(File("unused")), Files.createTempDirectory("media").toFile())
        val thumbnail = Source("mxc://example.org/thumbnail")
        assertEquals("mxc://example.org/thumbnail", media.picture(image(50_000_000, thumbnail), 400, 300)?.decodeToString())
        assertEquals("mxc://example.org/original", media.picture(image(2_000_000), 400, 300)?.decodeToString())
        assertNull("A huge original isn't fetched just to show a preview", media.picture(image(50_000_000), 400, 300))
        assertNull("Nor is one of unknown size", media.picture(image(null), 400, 300))
    }

    // capability: message.file
    @Test fun aDownloadKeepsItsContentAndStaysInsideTheAppsFolderWhateverItsName() = runTest {
        val download = Files.createTempFile("download", ".tmp").toFile().apply { writeText("quarterly numbers") }
        val folder = Files.createTempDirectory("media").toFile()
        val media = MatrixMedia(MediaClient(download), folder)
        val attachment = MessageAttachment(MessageAttachment.Kind.File, "../../Q3 report.pdf", "application/pdf", 17, null, null, original)
        val file = media.file(attachment)
        assertEquals("quarterly numbers", file.readText())
        assertEquals("Q3 report.pdf", file.name)
        assertTrue("Saved inside the app's media folder", file.canonicalPath.startsWith(folder.canonicalPath + File.separator))
    }
}
