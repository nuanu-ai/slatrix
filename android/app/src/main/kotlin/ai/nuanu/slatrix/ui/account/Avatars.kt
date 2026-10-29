package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.MatrixAvatars
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Pictures for avatar URLs at a size in pixels. */
interface AvatarLoader {
    /** A picture already in memory, so a row that comes back into view never flashes its initials. */
    fun cached(url: String, sizePx: Int): ImageBitmap? = null

    suspend fun load(url: String, sizePx: Int): ImageBitmap?
}

val LocalAvatarLoader = staticCompositionLocalOf<AvatarLoader> {
    object : AvatarLoader {
        override suspend fun load(url: String, sizePx: Int): ImageBitmap? = null
    }
}

/** Decodes [avatars]' thumbnails off the main thread and keeps them in memory for the session. */
class SessionAvatars(private val avatars: MatrixAvatars) : AvatarLoader {
    private val pictures = object : LruCache<String, ImageBitmap>(AvatarCacheBytes) {
        override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4
    }

    override fun cached(url: String, sizePx: Int): ImageBitmap? = pictures["$url@$sizePx"]

    override suspend fun load(url: String, sizePx: Int): ImageBitmap? = cached(url, sizePx)
        ?: avatars.thumbnail(url, sizePx)?.let { bytes -> withContext(Dispatchers.Default) { decode(bytes, sizePx) } }
            ?.also { pictures.put("$url@$sizePx", it) }

    /** A server may send the original for a thumbnail, so it is decoded at the power-of-two scale nearest the tile. */
    private fun decode(bytes: ByteArray, sizePx: Int): ImageBitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= sizePx && bounds.outHeight / (sample * 2) >= sizePx) sample *= 2
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
    }
}

private const val AvatarCacheBytes = 8 * 1024 * 1024

/** The picture at [url], once loaded; until then, and without one, null, so the initials underneath show. */
@Composable
internal fun rememberAvatar(url: String?, size: Dp): ImageBitmap? {
    val loader = LocalAvatarLoader.current
    val pixels = with(LocalDensity.current) { size.roundToPx() }
    // The state outlives a change of URL, so every change sets it, to the new picture or to none.
    val picture by produceState(url?.let { loader.cached(it, pixels) }, url, pixels, loader) {
        value = url?.let { loader.cached(it, pixels) ?: loader.load(it, pixels) }
    }
    return picture
}
