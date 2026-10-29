package ai.nuanu.slatrix

import ai.nuanu.slatrix.ui.account.EditProfileScreen
import ai.nuanu.slatrix.ui.account.PhotoCropScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import com.github.takahirom.roborazzi.captureScreenRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Renders Edit profile and the photo crop with fictional data for visual review, at the reference captures' size. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class EditProfileScreenshots(private val screen: String, private val dark: Boolean) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        // A made-up photo: sky over a field, with a sun to frame.
        val photo = Bitmap.createBitmap(1_200, 900, Bitmap.Config.ARGB_8888).apply {
            Canvas(this).apply {
                drawColor(Color.rgb(120, 170, 220))
                drawRect(0f, 600f, 1_200f, 900f, Paint().apply { color = Color.rgb(90, 150, 80) })
                drawCircle(760f, 330f, 140f, Paint().apply { color = Color.rgb(250, 210, 90) })
            }
        }.asImageBitmap()
        compose.setContent {
            SlatrixTheme(dark = dark) {
                val colors = SlatrixTheme.colors
                val bar = if (screen == "Crop") colors.mediaBackdrop else colors.canvas
                Column {
                    Box(Modifier.fillMaxWidth().height(48.8.dp).background(bar))
                    Box(Modifier.weight(1f)) {
                        when (screen) {
                            "Edit" -> EditProfileScreen("@alex:example.org", "Alex Doe", photo = null, hasPhoto = true, saving = false,
                                error = null, onPickPhoto = {}, onRemovePhoto = {}, onSave = {}, onBack = {})
                            "Crop" -> PhotoCropScreen(photo, onCancel = {}, onSave = {})
                        }
                    }
                    Box(Modifier.fillMaxWidth().height(24.dp).background(bar))
                }
            }
        }
        compose.waitForIdle()
        captureScreenRoboImage("build/outputs/roborazzi/Profile-$screen-${if (dark) "dark" else "light"}.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "{0}-{1}")
        fun cases(): List<Array<Any>> = listOf("Edit", "Crop").flatMap { screen -> listOf(false, true).map { arrayOf(screen, it) } }
    }
}
