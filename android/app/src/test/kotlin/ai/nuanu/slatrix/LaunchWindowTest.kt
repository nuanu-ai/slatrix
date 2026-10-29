package ai.nuanu.slatrix

import android.app.Application
import android.content.ComponentName
import android.view.ContextThemeWrapper
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import androidx.compose.ui.graphics.toArgb
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class LaunchWindowTest {
    @Test @Config(qualifiers = "night")
    fun aDarkLaunchOpensOnTheDarkCanvas() = assertLaunchBackground(dark = true)

    @Test @Config(qualifiers = "notnight")
    fun aLightLaunchOpensOnTheLightCanvas() = assertLaunchBackground(dark = false)

    private fun assertLaunchBackground(dark: Boolean) {
        val context = RuntimeEnvironment.getApplication()
        val theme = context.packageManager.getActivityInfo(ComponentName(context, MainActivity::class.java), 0).themeResource
        val attributes = ContextThemeWrapper(context, theme).obtainStyledAttributes(intArrayOf(android.R.attr.windowBackground))
        val background = attributes.getColor(0, 0)
        attributes.recycle()
        assertEquals(DesignTokens.colors(dark, SidebarPalette.Aubergine).getValue("canvas").toArgb(), background)
    }
}
