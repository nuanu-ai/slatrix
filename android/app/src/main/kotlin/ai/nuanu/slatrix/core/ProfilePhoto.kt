package ai.nuanu.slatrix.core

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import androidx.core.graphics.get
import androidx.core.graphics.scale
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client

/** A square in a photo's pixels, from its top-left. */
data class CropSquare(val x: Float, val y: Float, val side: Float)

/** Slack's crop frame, as `spec/photo-crop.json` has it: a square over the photo that moves and resizes without leaving it. */
object PhotoCrop {
    enum class Corner(val right: Boolean, val bottom: Boolean) {
        TopLeft(false, false), TopRight(true, false), BottomLeft(false, true), BottomRight(true, true)
    }

    /** The largest square in the middle, which Save uses untouched. */
    fun centered(width: Float, height: Float): CropSquare {
        val side = min(width, height)
        return CropSquare((width - side) / 2, (height - side) / 2, side)
    }

    fun moved(square: CropSquare, dx: Float, dy: Float, width: Float, height: Float) =
        square.copy(x = (square.x + dx).coerceIn(0f, width - square.side), y = (square.y + dy).coerceIn(0f, height - square.side))

    /** [corner] dragged while the opposite one stays put; never under a quarter of the short side, so it stays easy to grab. */
    fun resized(square: CropSquare, corner: Corner, dx: Float, dy: Float, width: Float, height: Float): CropSquare {
        val anchorX = if (corner.right) square.x else square.x + square.side
        val anchorY = if (corner.bottom) square.y else square.y + square.side
        // How far the drag goes along the frame's diagonal.
        val growth = ((if (corner.right) dx else -dx) + (if (corner.bottom) dy else -dy)) / 2
        val room = min(if (corner.right) width - anchorX else anchorX, if (corner.bottom) height - anchorY else anchorY)
        val side = min(max(square.side + growth, min(width, height) / 4), room)
        return CropSquare(if (corner.right) anchorX else anchorX - side, if (corner.bottom) anchorY else anchorY - side, side)
    }
}

/** A photo ready to upload, and its type. */
class PhotoUpload(val data: ByteArray, val mimeType: String)

/**
 * A profile photo, as on the Mac: a square of the picked photo, scaled down, since avatars draw a few hundred pixels wide
 * at most and a photo straight from a camera uploads slowly.
 */
object ProfilePhoto {
    private const val MaxPixels = 1_024

    /** The picked photo upright, at most twice the upload size, so a crop of half of it still makes a sharp photo. */
    suspend fun load(context: Context, uri: Uri): Bitmap? = withContext(Dispatchers.IO) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
                    val scale = min(1f, 2f * MaxPixels / max(info.size.width, info.size.height))
                    decoder.setTargetSize((info.size.width * scale).toInt().coerceAtLeast(1), (info.size.height * scale).toInt().coerceAtLeast(1))
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                }
            } else {
                // shortcut: Android 7–8 ignore a photo's orientation tag; read it with ExifInterface if they ever matter.
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
                var sample = 1
                while (max(bounds.outWidth, bounds.outHeight) / sample > 2 * MaxPixels) sample *= 2
                context.contentResolver.openInputStream(uri)?.use {
                    BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
    }

    /** The square [crop] of [bitmap], at most 1,024 pixels, as JPEG, or PNG where it is transparent so a logo keeps its background. */
    fun encode(bitmap: Bitmap, crop: CropSquare): PhotoUpload? {
        val bounds = Rect(crop.x.toInt(), crop.y.toInt(), (crop.x + crop.side).toInt(), (crop.y + crop.side).toInt())
        if (bounds.width() <= 0 || !bounds.intersect(0, 0, bitmap.width, bitmap.height)) return null
        val side = min(min(bounds.width(), bounds.height()), MaxPixels)
        val square = Bitmap.createBitmap(bitmap, bounds.left, bounds.top, bounds.width(), bounds.height())
        val scaled = square.scale(side, side)
        val opaque = !scaled.hasAlpha() || (0 until scaled.height step 8).all { y -> (0 until scaled.width step 8).all { x -> scaled[x, y] ushr 24 == 0xFF } }
        val output = ByteArrayOutputStream()
        if (!scaled.compress(if (opaque) Bitmap.CompressFormat.JPEG else Bitmap.CompressFormat.PNG, 85, output)) return null
        return PhotoUpload(output.toByteArray(), if (opaque) "image/jpeg" else "image/png")
    }
}

/** What Save does to your photo. */
sealed interface PhotoChange {
    class Upload(val data: ByteArray, val mimeType: String) : PhotoChange
    data object Remove : PhotoChange
}

/** Your own profile, which every client shows: a display name and a photo. */
class MatrixProfile(private val client: Client) {
    /**
     * Saves a new [name], if any, then the [photo] change, if any; null once both are saved, else what failed. A name already
     * saved matches the account afterwards, so trying again sends only the photo.
     */
    suspend fun save(name: String?, photo: PhotoChange?): String? = withContext(Dispatchers.Default) {
        try {
            if (name != null) client.setDisplayName(name)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return@withContext "Couldn’t save your name."
        }
        try {
            when (photo) {
                is PhotoChange.Upload -> client.uploadAvatar(photo.mimeType, photo.data)
                PhotoChange.Remove -> client.removeAvatar()
                null -> {}
            }
            null
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            "Couldn’t save your photo."
        }
    }
}
