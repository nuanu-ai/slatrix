package ai.nuanu.slatrix.core

import kotlin.math.max
import kotlin.math.roundToInt
import org.matrix.rustcomponents.sdk.AttachmentKind
import org.matrix.rustcomponents.sdk.ThumbnailInfo
import org.matrix.rustcomponents.sdk.UploadSource
import org.matrix.rustcomponents.sdk.VideoInfo

/** A video's poster, written beside its copy. */
data class VideoPoster(val path: String, val width: Int, val height: Int, val size: Long)

/**
 * What sending a video puts in its event, as Slack's videos carry: its size as shown, its length and a poster, so others
 * can reserve its box and show it before it plays. The cases are in spec/video-upload.json.
 */
object VideoUpload {
    const val POSTER_MAX_PIXELS = 800
    const val POSTER_AT_MILLIS = 1_000L
    const val POSTER_MIMETYPE = "image/jpeg"

    /** The video's size as shown: a track turned a quarter swaps its sides. */
    fun shown(width: Int?, height: Int?, rotation: Int): Pair<Int, Int>? {
        if (width == null || height == null) return null
        return if (rotation % 180 != 0) height to width else width to height
    }

    /** When the poster is taken: a second in, or halfway through a shorter clip; the start when the length isn't known. */
    fun posterAt(durationMillis: Long?): Long = durationMillis?.let { minOf(POSTER_AT_MILLIS, it / 2) } ?: 0

    /** The poster's size: the video's shape, at most [POSTER_MAX_PIXELS] on its longer side and never enlarged. */
    fun posterSize(width: Int, height: Int): Pair<Int, Int> {
        val scale = minOf(1.0, POSTER_MAX_PIXELS.toDouble() / max(width, height))
        return max(1, (width * scale).roundToInt()) to max(1, (height * scale).roundToInt())
    }

    /** The upload and its kind: the video under its own name, with its poster going up beside it. */
    fun attachment(video: OutgoingAttachment): Pair<UploadSource, AttachmentKind> {
        val poster = video.poster
        val info = VideoInfo(video.durationMillis?.let(java.time.Duration::ofMillis), video.height?.toULong(), video.width?.toULong(),
            video.mimeType, video.size.toULong(),
            poster?.let { ThumbnailInfo(it.height.toULong(), it.width.toULong(), POSTER_MIMETYPE, it.size.toULong()) }, null, null)
        return UploadSource.File(video.path) to AttachmentKind.Video(info, poster?.let { UploadSource.File(it.path) })
    }
}
