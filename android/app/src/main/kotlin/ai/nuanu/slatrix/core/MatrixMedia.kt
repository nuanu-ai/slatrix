package ai.nuanu.slatrix.core

import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client

/** Fetches attachments through the SDK, which decrypts them and keeps them in its media store. */
class MatrixMedia(private val client: Client, private val folder: File) {
    /**
     * A picture of an image or video no bigger than [width]×[height] pixels. Inline it is the sender's thumbnail, or
     * else an image small enough to fetch whole, since the SDK downloads all of an encrypted original even for a
     * thumbnail; [full] prefers that original, for the viewer. Nothing over the size limit is fetched to preview it.
     */
    suspend fun picture(attachment: MessageAttachment, width: Int, height: Int, full: Boolean = false): ByteArray? {
        val original = attachment.source.takeIf { attachment.kind == MessageAttachment.Kind.Image && small(attachment.size) }
        val thumbnail = attachment.thumbnail?.takeIf { small(attachment.thumbnailSize) }
        val source = (if (full) original ?: thumbnail else thumbnail ?: original) ?: return null
        return client.getMediaThumbnail(source, width.toULong(), height.toULong()).takeIf { small(it.size.toLong()) }
    }

    /** The whole file, downloaded once into a folder of its own and named as sent, for another app to open. */
    suspend fun file(attachment: MessageAttachment): File {
        // The name comes from the sender: any folders in it are dropped, and a long one is cut, keeping its extension.
        val sent = attachment.name.substringAfterLast('/').substringAfterLast('\\').trim()
            .takeUnless { it.isEmpty() || it == "." || it == ".." } ?: "file"
        val extension = sent.substringAfterLast('.', "").take(MAX_EXTENSION)
        val name = when {
            sent.length <= MAX_NAME -> sent
            extension.isEmpty() -> sent.take(MAX_NAME)
            else -> sent.take(MAX_NAME - extension.length - 1) + "." + extension
        }
        val target = File(File(folder, digest(attachment.source.url())), name)
        if (target.isFile) return target
        client.getMediaFile(attachment.source, name, attachment.mimeType ?: "application/octet-stream", true, null).use { handle ->
            withContext(Dispatchers.IO) {
                val directory = checkNotNull(target.parentFile).apply { mkdirs() }
                // Copied under a name of its own first, so a download cut short, or two at once, never look complete.
                val partial = File.createTempFile("download", ".part", directory)
                try {
                    File(handle.path()).copyTo(partial, overwrite = true)
                    check(partial.renameTo(target) || target.isFile)
                } finally {
                    partial.delete()
                }
            }
        }
        return target
    }

    private fun small(size: Long?) = size != null && size <= MAX_PREVIEW_BYTES

    private fun digest(text: String) =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

    private companion object {
        const val MAX_PREVIEW_BYTES = 10L * 1024 * 1024
        // File systems take 255 bytes; this leaves room for any letter's UTF-8.
        const val MAX_NAME = 60
        const val MAX_EXTENSION = 10
    }
}
