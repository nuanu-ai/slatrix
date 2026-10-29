package ai.nuanu.slatrix.core

import android.app.Application
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.NoHandle
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Your profile photo: the crop frame's shared rules, the square that uploads, and saving it with your name. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35])
class ProfilePhotoTest {
    private val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/photo-crop.json").readText()).asJsonObject

    private fun JsonObject.numbers(key: String) = this[key].asJsonArray.map { it.asFloat }
    private fun square(values: List<Float>) = CropSquare(values[0], values[1], values[2])

    @Test fun theCropFrameFollowsEverySharedCase() {
        for (item in spec["centered"].asJsonArray) {
            val case = item.asJsonObject
            val (width, height) = case.numbers("photo")
            assertEquals(case["name"].asString, square(case.numbers("expected")), PhotoCrop.centered(width, height))
        }
        for (item in spec["moved"].asJsonArray) {
            val case = item.asJsonObject
            val (width, height) = case.numbers("photo")
            val (dx, dy) = case.numbers("by")
            assertEquals(case["name"].asString, square(case.numbers("expected")),
                PhotoCrop.moved(square(case.numbers("square")), dx, dy, width, height))
        }
        val corners = mapOf("topLeft" to PhotoCrop.Corner.TopLeft, "topRight" to PhotoCrop.Corner.TopRight,
            "bottomLeft" to PhotoCrop.Corner.BottomLeft, "bottomRight" to PhotoCrop.Corner.BottomRight)
        for (item in spec["resized"].asJsonArray) {
            val case = item.asJsonObject
            val (width, height) = case.numbers("photo")
            val (dx, dy) = case.numbers("by")
            assertEquals(case["name"].asString, square(case.numbers("expected")),
                PhotoCrop.resized(square(case.numbers("square")), corners.getValue(case["corner"].asString), dx, dy, width, height))
        }
    }

    // capability: profile.edit-photo
    @Test fun theUploadIsTheChosenSquareSmallEnoughForAvatars() {
        // Red on the left half, blue on the right: the right-hand square is all blue.
        val photo = Bitmap.createBitmap(3_000, 1_500, Bitmap.Config.ARGB_8888)
        Canvas(photo).apply {
            drawColor(Color.RED)
            drawRect(1_500f, 0f, 3_000f, 1_500f, Paint().apply { color = Color.BLUE })
        }
        val upload = ProfilePhoto.encode(photo, CropSquare(1_500f, 0f, 1_500f))!!
        val decoded = BitmapFactory.decodeByteArray(upload.data, 0, upload.data.size)

        assertEquals("image/jpeg", upload.mimeType)
        assertEquals(1_024, decoded.width)
        assertEquals(1_024, decoded.height)
        val corner = decoded.getPixel(10, 10)
        assertTrue("The chosen square, not the middle", Color.blue(corner) > 200 && Color.red(corner) < 60)
    }

    @Test fun aPhotoWithTransparencyKeepsIt() {
        val logo = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.TRANSPARENT) }
        assertEquals("image/png", ProfilePhoto.encode(logo, CropSquare(0f, 0f, 64f))!!.mimeType)
    }

    // capability: profile.edit-name
    // capability: profile.edit-photo
    @Test fun savingSetsTheNameThenThePhoto() = runTest {
        val client = ProfileClient()
        assertNull(MatrixProfile(client).save("Alex Doe", PhotoChange.Upload(byteArrayOf(1, 2), "image/png")))
        assertEquals(listOf("name Alex Doe", "upload image/png 2"), client.calls)
    }

    // capability: profile.edit-photo
    @Test fun aRemovedPhotoIsRemovedAndANameLeftAloneIsntSent() = runTest {
        val client = ProfileClient()
        assertNull(MatrixProfile(client).save(null, PhotoChange.Remove))
        assertEquals(listOf("remove"), client.calls)
    }

    @Test fun aPhotoThatFailsToUploadSaysSoAfterTheNameIsSaved() = runTest {
        val client = ProfileClient().apply { uploadFails = true }
        assertEquals("Couldn’t save your photo.", MatrixProfile(client).save("Alex Doe", PhotoChange.Upload(byteArrayOf(1), "image/jpeg")))
        assertEquals(listOf("name Alex Doe"), client.calls)
    }
}

private class ProfileClient : Client(NoHandle) {
    val calls = mutableListOf<String>()
    var uploadFails = false
    override suspend fun setDisplayName(name: String) { calls += "name $name" }
    override suspend fun uploadAvatar(mimeType: String, data: ByteArray) {
        if (uploadFails) throw IllegalStateException("Too large")
        calls += "upload $mimeType ${data.size}"
    }
    override suspend fun removeAvatar() { calls += "remove" }
}
