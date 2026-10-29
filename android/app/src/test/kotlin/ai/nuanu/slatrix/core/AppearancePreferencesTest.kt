package ai.nuanu.slatrix.core

import android.app.Application
import android.app.UiModeManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class AppearancePreferencesTest {
    // capability: app.appearance
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

    @Test fun theSystemStartsTheAppInTheChosenColorMode() {
        val context = RuntimeEnvironment.getApplication()
        val system = context.getSystemService(UiModeManager::class.java)
        AppearancePreferences(context).darkMode = true
        assertEquals(UiModeManager.MODE_NIGHT_YES, shadowOf(system).applicationNightMode)

        AppearancePreferences(context).darkMode = null
        assertEquals(UiModeManager.MODE_NIGHT_AUTO, shadowOf(system).applicationNightMode)
    }

    @Test fun aChoiceSavedByAnEarlierVersionReachesTheSystemAtStart() {
        val context = RuntimeEnvironment.getApplication()
        val system = context.getSystemService(UiModeManager::class.java)
        AppearancePreferences(context).darkMode = false
        system.setApplicationNightMode(UiModeManager.MODE_NIGHT_AUTO)

        AppearancePreferences(context).applyNightMode()
        assertEquals(UiModeManager.MODE_NIGHT_NO, shadowOf(system).applicationNightMode)
    }
}
