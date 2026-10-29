package ai.nuanu.slatrix.core

import android.graphics.Bitmap
import org.matrix.rustcomponents.sdk.Client

data class CropSquare(val x: Float, val y: Float, val side: Float)

object PhotoCrop {
    enum class Corner { TopLeft, TopRight, BottomLeft, BottomRight }
    fun centered(width: Float, height: Float) = CropSquare(0f, 0f, 0f)
    fun moved(square: CropSquare, dx: Float, dy: Float, width: Float, height: Float) = square
    fun resized(square: CropSquare, corner: Corner, dx: Float, dy: Float, width: Float, height: Float) = square
}

class PhotoUpload(val data: ByteArray, val mimeType: String)

object ProfilePhoto {
    fun encode(bitmap: Bitmap, crop: CropSquare): PhotoUpload? = null
}

sealed interface PhotoChange {
    class Upload(val data: ByteArray, val mimeType: String) : PhotoChange
    data object Remove : PhotoChange
}

class MatrixProfile(private val client: Client) {
    suspend fun save(name: String?, photo: PhotoChange?): String? = "Couldn’t save."
}
