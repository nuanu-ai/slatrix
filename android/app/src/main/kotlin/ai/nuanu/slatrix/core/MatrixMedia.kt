package ai.nuanu.slatrix.core

import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client

/** Fetches attachments through the SDK, which decrypts them and keeps them in its media store. */
class MatrixMedia(private val client: Client, private val folder: File) {
    /**
     * A picture of an image or video no bigger than [width]×[height] pixels: the sender's thumbnail, or else an image
     * small enough to fetch whole, since the SDK downloads all of an encrypted original even for a thumbnail.
     */
    suspend fun picture(attachment: MessageAttachment, width: Int, height: Int): ByteArray? {
        val source = attachment.thumbnail ?: attachment.source.takeIf {
            attachment.kind == MessageAttachment.Kind.Image && (attachment.size ?: Long.MAX_VALUE) <= MAX_PREVIEW_BYTES
        } ?: return null
        return client.getMediaThumbnail(source, width.toULong(), height.toULong()).takeIf { it.size <= MAX_PREVIEW_BYTES }
    }

    /** The whole file, downloaded once into a folder of its own and named as sent, for another app to open. */
    suspend fun file(attachment: MessageAttachment): File {
        // The name comes from the sender, so any folders in it are dropped.
        val name = attachment.name.substringAfterLast('/').substringAfterLast('\\').trim()
            .takeUnless { it.isEmpty() || it == "." || it == ".." } ?: "file"
        val target = File(File(folder, digest(attachment.source.url())), name)
        if (target.isFile) return target
        val handle = client.getMediaFile(attachment.source, name, attachment.mimeType ?: "application/octet-stream", true, null)
        handle.use {
            withContext(Dispatchers.IO) {
                target.parentFile?.mkdirs()
                // Copied under another name first, so a download cut short never looks complete.
                val partial = File(target.parentFile, "$name.part")
                File(it.path()).copyTo(partial, overwrite = true)
                check(partial.renameTo(target))
            }
        }
        return target
    }

    private fun digest(text: String) =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

    private companion object {
        const val MAX_PREVIEW_BYTES = 10L * 1024 * 1024
    }
}
