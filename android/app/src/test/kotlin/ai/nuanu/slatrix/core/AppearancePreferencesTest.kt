package ai.nuanu.slatrix.core

import android.app.Application
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class AppearancePreferencesTest {
    @Test fun chosenAppearanceSurvivesOpeningSettingsAgain() {
        val context = RuntimeEnvironment.getApplication()
        val settings = AppearancePreferences(context)
        settings.darkMode = false
        settings.paletteName = "Lagoon"

        val reopened = AppearancePreferences(context)
        assertEquals(false, reopened.darkMode)
        assertEquals("Lagoon", reopened.paletteName)

        reopened.darkMode = null
        assertNull(AppearancePreferences(context).darkMode)
    }
}
