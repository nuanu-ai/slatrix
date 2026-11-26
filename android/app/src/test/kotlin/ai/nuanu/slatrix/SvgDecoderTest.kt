package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.SvgDecoder
import ai.nuanu.slatrix.ui.account.decode
import ai.nuanu.slatrix.ui.account.resolveAttachmentMimeType
import android.app.Application
import android.graphics.Color
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35])
class SvgDecoderTest {
    private val svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 200 100">
          <rect width="200" height="100" fill="#2563eb"/>
        </svg>
    """.trimIndent().toByteArray()

    @Test fun decodesSvgPreservingAspectRatioAndDrawingPixels() {
        val bitmap = SvgDecoder.decode(svg, 400, 400)
        assertNotNull(bitmap)
        assertEquals(400, bitmap!!.width)
        assertEquals(200, bitmap.height)
        assertEquals(Color.rgb(0x25, 0x63, 0xeb), bitmap.getPixel(200, 100))

        val image = decode(svg, 360, 270, fit = false)
        assertNotNull(image)
        assertEquals(360, image!!.width)
        assertEquals(180, image.height)
    }

    @Test fun addsContrastMatteToTransparentDarkInkSvg() {
        val darkLine = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100">
              <line x1="20" y1="50" x2="180" y2="50" stroke="#111111" stroke-width="16"/>
            </svg>
        """.trimIndent().toByteArray()
        val bitmap = SvgDecoder.decode(darkLine, 200, 100)
        assertNotNull(bitmap)
        val corner = bitmap!!.getPixel(2, 2)
        assertEquals(255, Color.alpha(corner))
        assertTrue(Color.red(corner) > 230)
    }

    @Test fun readsIntrinsicDimensionsRejectsNonSvgAndNormalizesMimeTypes() {
        assertEquals(200 to 100, SvgDecoder.dimensions(svg))
        val pdf = "%PDF-1.4\n1 0 obj\n<<>>\nendobj\n%%EOF".toByteArray()
        assertNull(SvgDecoder.decode(pdf, 400, 400))
        assertNull(decode(pdf, 400, 400, fit = true))

        val context = ApplicationProvider.getApplicationContext<Application>()
        val uri = Uri.parse("content://ai.nuanu.slatrix.dev.files/test")
        assertEquals("image/svg+xml", resolveAttachmentMimeType(context, uri, "icons.svg", "application/octet-stream"))
        assertEquals("text/plain", resolveAttachmentMimeType(context, uri, "notes.txt", "text/plain; charset=utf-8"))
    }
}
