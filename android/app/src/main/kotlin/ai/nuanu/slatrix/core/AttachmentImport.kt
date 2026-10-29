package ai.nuanu.slatrix.core

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** A picked file, copied where the SDK can read it, with what its event says about it. */
data class OutgoingAttachment(val path: String, val name: String, val mimeType: String, val size: Long,
    val width: Int?, val height: Int?)

/** Copies what the system picker hands over into the app's cache, since its permission ends with the picker. */
// The platform's ExifInterface reads a file's orientation correctly from API 24, the app's minimum.
@SuppressLint("ExifInterface")
class AttachmentImport(private val context: Context) {
    suspend fun prepare(uri: Uri): OutgoingAttachment = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        } ?: uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        val mimeType = resolver.getType(uri)
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
            ?: "application/octet-stream"
        // Its own folder, so the name stays the one people see and two picks of the same name don't collide.
        val copy = File(File(context.cacheDir, "attachments/${UUID.randomUUID()}").apply { mkdirs() }, File(name).name.ifBlank { "file" })
        checkNotNull(resolver.openInputStream(uri)).use { input -> copy.outputStream().use { input.copyTo(it) } }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            .takeIf { mimeType.startsWith("image/") }?.also { BitmapFactory.decodeFile(copy.path, it) }
            ?.takeIf { it.outWidth > 0 && it.outHeight > 0 }
        // EXIF orientations 5 to 8 turn the picture a quarter, so its width and height swap.
        val turned = bounds != null && runCatching {
            android.media.ExifInterface(copy.path).getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, 1) in 5..8
        }.getOrDefault(false)
        OutgoingAttachment(copy.path, name, mimeType, copy.length(),
            bounds?.let { if (turned) it.outHeight else it.outWidth }, bounds?.let { if (turned) it.outWidth else it.outHeight })
    }
}
