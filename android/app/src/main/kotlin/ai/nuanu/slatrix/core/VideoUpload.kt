package ai.nuanu.slatrix.core

import org.matrix.rustcomponents.sdk.AttachmentKind
import org.matrix.rustcomponents.sdk.UploadSource
import org.matrix.rustcomponents.sdk.VideoInfo

/** A video's poster, written beside its copy. */
data class VideoPoster(val path: String, val width: Int, val height: Int, val size: Long)

object VideoUpload {
    fun shown(width: Int?, height: Int?, rotation: Int): Pair<Int, Int>? = if (width == null || height == null) null else width to height

    fun posterAt(durationMillis: Long?): Long = 0

    fun posterSize(width: Int, height: Int): Pair<Int, Int> = width to height

    fun attachment(video: OutgoingAttachment): Pair<UploadSource, AttachmentKind> = UploadSource.File(video.path) to
        AttachmentKind.Video(VideoInfo(video.durationMillis?.let(java.time.Duration::ofMillis), video.height?.toULong(),
            video.width?.toULong(), video.mimeType, video.size.toULong(), null, null, null), null)
}
