package ai.nuanu.slatrix.core

import kotlinx.coroutines.CancellationException
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.MediaSource

/** Avatar thumbnails through the SDK, which keeps them in its media store. */
class MatrixAvatars(private val client: Client) {
    /** The picture at an `mxc:` [url], scaled to about [size] pixels square, or null when it can't be had. */
    suspend fun thumbnail(url: String, size: Int): ByteArray? = try {
        MediaSource.fromUrl(url).use { client.getMediaThumbnail(it, size.toULong(), size.toULong()) }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }
}
