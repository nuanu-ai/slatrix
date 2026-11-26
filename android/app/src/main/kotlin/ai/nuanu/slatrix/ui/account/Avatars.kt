package ai.nuanu.slatrix.ui.account

import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Pictures for avatar URLs at a size in pixels. */
interface AvatarLoader {
    /**
     * A picture already in memory, so a row that comes back into view never flashes its initials: at [sizePx], or until
     * that loads, at another size.
     */
    fun cached(url: String, sizePx: Int): ImageBitmap? = null

    suspend fun load(url: String, sizePx: Int): ImageBitmap?
}

val LocalAvatarLoader = staticCompositionLocalOf<AvatarLoader> {
    object : AvatarLoader {
        override suspend fun load(url: String, sizePx: Int): ImageBitmap? = null
    }
}

/** Decodes [thumbnail]'s pictures, by URL and size, off the main thread and keeps them in memory for the session. */
class SessionAvatars(private val thumbnail: suspend (url: String, sizePx: Int) -> ByteArray?) : AvatarLoader {
    private val pictures = object : LruCache<String, ImageBitmap>(AvatarCacheBytes) {
        override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4
    }

    override fun cached(url: String, sizePx: Int): ImageBitmap? =
        pictures["$url@$sizePx"] ?: pictures.snapshot().filterKeys { it.startsWith("$url@") }.values.maxByOrNull { it.width }

    override suspend fun load(url: String, sizePx: Int): ImageBitmap? = pictures["$url@$sizePx"]
        ?: thumbnail(url, sizePx)?.let { bytes -> withContext(Dispatchers.Default) { decode(bytes, sizePx) } }
            ?.also { pictures.put("$url@$sizePx", it) }

    /** Decodes upright via ImageDecoder (honoring EXIF orientation) and downscales to the avatar tile. */
    private fun decode(bytes: ByteArray, sizePx: Int): ImageBitmap? = runCatching {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val w = info.size.width
            val h = info.size.height
            if (w > 0 && h > 0) {
                val scale = min(1f, sizePx.toFloat() / min(w, h))
                decoder.setTargetSize(max(1, (w * scale).roundToInt()), max(1, (h * scale).roundToInt()))
            }
        }.asImageBitmap()
    }.getOrElse {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= sizePx && bounds.outHeight / (sample * 2) >= sizePx) sample *= 2
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
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
        value = url?.let { loader.cached(it, pixels) }
        // The size asked for replaces one cached at another size, which stays if it doesn't load.
        url?.let { loader.load(it, pixels) }?.let { value = it }
    }
    return picture
}
