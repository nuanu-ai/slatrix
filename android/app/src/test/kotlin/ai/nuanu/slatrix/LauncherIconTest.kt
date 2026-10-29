package ai.nuanu.slatrix

import android.app.Application
import android.content.ComponentName
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.AdaptiveIconDrawable
import android.view.ContextThemeWrapper
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import androidx.compose.ui.graphics.toArgb
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35])
class LauncherIconTest {
    private val context = RuntimeEnvironment.getApplication()

    // capability: app.icon
    @Test fun theLauncherIconFillsTheLauncherShapeAndHasAThemedLayer() {
        val icon = context.getDrawable(context.applicationInfo.icon)
        assertTrue("A legacy bitmap gets shrunk into a white circle", icon is AdaptiveIconDrawable)
        icon as AdaptiveIconDrawable
        assertNotNull("Themed icons need a monochrome layer", icon.monochrome)

        // Launchers mask the middle 72 of the 108 units; the icon's own color must reach the mask's edge.
        val size = 108
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        icon.background.setBounds(0, 0, size, size)
        icon.background.draw(Canvas(bitmap))
        for ((x, y) in listOf(18 to 54, 89 to 54, 54 to 18, 54 to 89, 20 to 20, 87 to 87)) {
            val pixel = bitmap.getPixel(x, y)
            assertEquals("Opaque at ($x, $y)", 0xff, pixel ushr 24)
            assertTrue("Dark navy at ($x, $y), not white", (pixel and 0xff) < 0x60)
        }
    }

    @Test @Config(qualifiers = "night")
    fun aDarkSplashSitsOnTheDarkCanvas() = assertSplashBackground(dark = true)

    @Test @Config(qualifiers = "notnight")
    fun aLightSplashSitsOnTheLightCanvas() = assertSplashBackground(dark = false)

    private fun assertSplashBackground(dark: Boolean) {
        val theme = context.packageManager.getActivityInfo(ComponentName(context, MainActivity::class.java), 0).themeResource
        val attributes = ContextThemeWrapper(context, theme).obtainStyledAttributes(intArrayOf(android.R.attr.windowSplashScreenBackground))
        val background = attributes.getColor(0, 0)
        attributes.recycle()
        assertEquals(DesignTokens.colors(dark, SidebarPalette.Aubergine).getValue("canvas").toArgb(), background)
    }
}
