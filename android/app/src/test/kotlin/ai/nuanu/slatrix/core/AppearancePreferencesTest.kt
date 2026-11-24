package ai.nuanu.slatrix.core

import android.app.Application
import android.app.UiModeManager
import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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
    // capability: app.themes
    @Test fun chosenAppearanceAndThemeTogglesSurviveReopening() {
        val context = RuntimeEnvironment.getApplication()
        val settings = AppearancePreferences(context)
        assertEquals(AndroidTheme.Neutral, settings.theme)
        assertTrue(settings.chatWallpaper)
        assertFalse(settings.increaseContrast)
        assertEquals(emptyMap<String, AndroidTheme>(), settings.workspaceThemes)

        settings.darkMode = false
        settings.theme = AndroidTheme.Aubergine
        settings.chatWallpaper = false
        settings.increaseContrast = true

        val reopened = AppearancePreferences(context)
        assertEquals(false, reopened.darkMode)
        assertEquals(AndroidTheme.Aubergine, reopened.theme)
        assertFalse(reopened.chatWallpaper)
        assertTrue(reopened.increaseContrast)

        for (choice in AndroidTheme.entries) {
            reopened.theme = choice
            assertEquals(choice, AppearancePreferences(context).theme)
        }

        reopened.darkMode = null
        assertNull(AppearancePreferences(context).darkMode)
    }

    // capability: app.themes
    @Test fun legacyWallpaperColorsMigratesToMaterialYouUntilThemeIsChosen() {
        val context = RuntimeEnvironment.getApplication()
        val raw = context.getSharedPreferences("appearance", Context.MODE_PRIVATE)
        raw.edit().putBoolean("wallpaperColors", true).commit()

        val migrated = AppearancePreferences(context)
        assertEquals(AndroidTheme.MaterialYou, migrated.theme)
        assertEquals(AndroidTheme.MaterialYou, migrated.effectiveTheme(null))

        migrated.theme = AndroidTheme.Neutral
        assertEquals(AndroidTheme.Neutral, AppearancePreferences(context).theme)
    }

    // capability: app.themes
    @Test fun perWorkspaceThemeOverridesPersistResolveAndResetToGlobalDefault() {
        val context = RuntimeEnvironment.getApplication()
        val settings = AppearancePreferences(context)
        settings.theme = AndroidTheme.Sand

        val harbor = "!harbor:example.org"
        val studio = "!studio:example.org"
        settings.setWorkspaceTheme(harbor, AndroidTheme.Jade)
        settings.setWorkspaceTheme(studio, AndroidTheme.Ocean)
        settings.setWorkspaceTheme("   ", AndroidTheme.Aubergine)

        val reopened = AppearancePreferences(context)
        assertEquals(mapOf(harbor to AndroidTheme.Jade, studio to AndroidTheme.Ocean), reopened.workspaceThemes)
        assertEquals(AndroidTheme.Jade, reopened.effectiveTheme(harbor))
        assertEquals(AndroidTheme.Ocean, reopened.effectiveTheme(studio))
        assertEquals(AndroidTheme.Sand, reopened.effectiveTheme("!other:example.org"))
        assertEquals(AndroidTheme.Sand, reopened.effectiveTheme(null))

        reopened.setWorkspaceTheme(harbor, null)
        val afterReset = AppearancePreferences(context)
        assertEquals(mapOf(studio to AndroidTheme.Ocean), afterReset.workspaceThemes)
        assertEquals(AndroidTheme.Sand, afterReset.effectiveTheme(harbor))
    }

    // capability: app.themes
    @Test fun plantedInvalidThemePreferencesDegradeSafelyToDefaults() {
        val context = RuntimeEnvironment.getApplication()
        val raw = context.getSharedPreferences("appearance", Context.MODE_PRIVATE)
        raw.edit()
            .putString("theme", "unknown-theme")
            .putString("workspaceThemes", """{"!ok:example.org":"ocean","!bad:example.org":"nope","":"jade"}""")
            .commit()

        val settings = AppearancePreferences(context)
        assertEquals(AndroidTheme.Neutral, settings.theme)
        assertEquals(mapOf("!ok:example.org" to AndroidTheme.Ocean), settings.workspaceThemes)

        raw.edit().putString("workspaceThemes", "not-json").commit()
        assertEquals(emptyMap<String, AndroidTheme>(), AppearancePreferences(context).workspaceThemes)
    }

    @Test fun messageTextSizeSurvivesReopeningAndAPlantedSizeFallsBackToTheDefault() {
        val context = RuntimeEnvironment.getApplication()
        val bigger = AppearancePreferences.MessageScales.last()
        AppearancePreferences(context).messageScale = bigger
        assertEquals(bigger, AppearancePreferences(context).messageScale)

        context.getSharedPreferences("appearance", Context.MODE_PRIVATE).edit().putFloat("messageScale", 40f).commit()
        assertEquals(1f, AppearancePreferences(context).messageScale)
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
