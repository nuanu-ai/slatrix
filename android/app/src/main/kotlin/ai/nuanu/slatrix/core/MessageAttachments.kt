package ai.nuanu.slatrix.core

import org.matrix.rustcomponents.sdk.MediaSource

/** A message's file, image, video or recording, and what its row needs to show it before anything downloads. */
data class MessageAttachment(
    val kind: Kind,
    val name: String,
    val mimeType: String?,
    val size: Long?,
    /** Pixels, from the event, so an image's box is reserved before it loads. */
    val width: Int?,
    val height: Int?,
    /** Where the file comes from: an opaque SDK handle that only the media loader reads. */
    val source: MediaSource,
    /** The sender's own small picture of it, when they attached one. */
    val thumbnail: MediaSource? = null,
    val thumbnailSize: Long? = null,
) {
    enum class Kind { Image, Video, Audio, File }
}

/** What kind of file an attachment is, for its tile and card, by the rule in spec/file-kind.json. */
enum class FileKind(private val title: String, extensions: String) {
    Pdf("PDF", "pdf"),
    Document("Document", "doc docx pages odt rtf txt md"),
    Spreadsheet("Spreadsheet", "xls xlsx numbers ods csv tsv"),
    Presentation("Presentation", "ppt pptx key odp"),
    Archive("Archive", "zip gz tgz tar rar 7z bz2 xz dmg"),
    Code("Code", "swift js ts py rb go rs java kt c h cpp m json yaml yml xml html css sh sql"),
    Audio("Audio", "mp3 m4a wav aac ogg opus flac"),
    Video("Video", "mp4 mov m4v webm mkv avi"),
    Image("Image", "png jpg jpeg gif heic webp tiff bmp svg"),
    Generic("File", "");

    private val extensions = extensions.split(' ').toSet()

    /** Its color's name in design/tokens.json's fileColors. */
    val token: String get() = name.lowercase()

    /** "PDF", or the extension in capitals, as a file's card shows its type. */
    fun label(fileName: String): String = extension(fileName).let { if (this == Pdf || it.isEmpty()) title else it.uppercase() }

    companion object {
        /** In order: the first fragment the MIME type contains wins. */
        private val mimeTypes = listOf("pdf" to Pdf, "spreadsheet" to Spreadsheet, "ms-excel" to Spreadsheet,
            "csv" to Spreadsheet, "presentation" to Presentation, "ms-powerpoint" to Presentation,
            "wordprocessing" to Document, "msword" to Document, "rtf" to Document, "text/plain" to Document,
            "zip" to Archive, "tar" to Archive, "rar" to Archive, "7z" to Archive, "json" to Code, "javascript" to Code,
            "xml" to Code, "html" to Code, "text/x-" to Code, "audio/" to Audio, "video/" to Video, "image/" to Image)

        /** The extension decides, since senders often label files application/octet-stream; the MIME type is the fallback. */
        fun of(name: String, mimeType: String?): FileKind {
            val extension = extension(name).lowercase()
            entries.firstOrNull { extension.isNotEmpty() && extension in it.extensions }?.let { return it }
            val mime = mimeType?.lowercase().orEmpty()
            return mimeTypes.firstOrNull { mime.contains(it.first) }?.second ?: Generic
        }

        internal fun extension(name: String) = name.substringAfterLast('/').let { file ->
            file.substringAfterLast('.', "").takeIf { file.lastIndexOf('.') > 0 }.orEmpty()
        }
    }
}
