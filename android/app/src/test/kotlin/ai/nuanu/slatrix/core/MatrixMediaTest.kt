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
    private val thumbnail = Source("mxc://example.org/thumbnail")
    private fun image(size: Long?, thumbnailSize: Long? = null) = MessageAttachment(MessageAttachment.Kind.Image, "photo.jpg",
        "image/jpeg", size, 1600, 900, original, thumbnail.takeIf { thumbnailSize != null }, thumbnailSize)

    // capability: message.image
    @Test fun aPictureComesFromTheSendersThumbnailOrASmallOriginalAndNeverFromAHugeOne() = runTest {
        val media = MatrixMedia(MediaClient(File("unused")), Files.createTempDirectory("media").toFile())
        suspend fun inline(attachment: MessageAttachment) = media.picture(attachment, 400, 300)?.decodeToString()
        assertEquals("mxc://example.org/thumbnail", inline(image(50_000_000, thumbnailSize = 40_000)))
        assertEquals("mxc://example.org/original", inline(image(2_000_000)))
        assertNull("A huge original isn't fetched just to show a preview", inline(image(50_000_000)))
        assertNull("Nor is one of unknown size", inline(image(null)))
        assertNull("Nor a huge thumbnail", inline(image(50_000_000, thumbnailSize = 50_000_000)))
    }

    // capability: message.image
    @Test fun aPhotoStillSendingShowsFromTheFileBeingSent() = runTest {
        // The send queue keeps a photo from the camera or the keyboard as a whole file; the server has no thumbnail yet.
        val client = object : Client(NoHandle) {
            override suspend fun getMediaThumbnail(mediaSource: MediaSource, width: ULong, height: ULong): ByteArray =
                throw IllegalStateException("Not on the server yet")
            override suspend fun getMediaContent(mediaSource: MediaSource): ByteArray = "the photo being sent".toByteArray()
        }
        val media = MatrixMedia(client, Files.createTempDirectory("media").toFile())
        assertEquals("the photo being sent", media.picture(image(2_000_000), 400, 300)?.decodeToString())
    }

    // capability: message.media-viewer
    @Test fun theViewerShowsTheOriginalWhenItIsSmallEnoughAndTheThumbnailOtherwise() = runTest {
        val media = MatrixMedia(MediaClient(File("unused")), Files.createTempDirectory("media").toFile())
        suspend fun full(attachment: MessageAttachment) = media.picture(attachment, 2048, 2048, full = true)?.decodeToString()
        assertEquals("mxc://example.org/original", full(image(2_000_000, thumbnailSize = 40_000)))
        assertEquals("mxc://example.org/thumbnail", full(image(50_000_000, thumbnailSize = 40_000)))
    }

    // capability: message.file
    @Test fun aDownloadKeepsItsContentAndStaysInsideTheAppsFolderWhateverItsName() = runTest {
        val download = Files.createTempFile("download", ".tmp").toFile().apply { writeText("quarterly numbers") }
        val folder = Files.createTempDirectory("media").toFile()
        val media = MatrixMedia(MediaClient(download), folder)
        fun file(name: String) = MessageAttachment(MessageAttachment.Kind.File, name, "application/pdf", 17, null, null, Source("mxc://example.org/$name"))
        val report = media.file(file("../../Q3 report.pdf"))
        assertEquals("quarterly numbers", report.readText())
        assertEquals("Q3 report.pdf", report.name)
        assertTrue("Saved inside the app's media folder", report.canonicalPath.startsWith(folder.canonicalPath + File.separator))
        val long = media.file(file("x".repeat(300) + ".pdf"))
        assertEquals("A name too long for the file system is cut but keeps its type", "pdf", long.extension)
        assertEquals("quarterly numbers", long.readText())
    }
}
