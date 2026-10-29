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
) {
    enum class Kind { Image, Video, Audio, File }
}

enum class FileKind {
    Pdf, Document, Spreadsheet, Presentation, Archive, Code, Audio, Video, Image, Generic;

    companion object {
        fun of(name: String, mimeType: String?): FileKind = Generic
        fun label(name: String, kind: FileKind): String = ""
    }

    /** Its color's name in design/tokens.json's fileColors. */
    val token: String get() = name.lowercase()
}
