package ai.nuanu.slatrix.core

import android.app.UiModeManager
import android.content.Context
import androidx.core.content.edit

class AppearancePreferences(private val context: Context) {
    private val values = context.getSharedPreferences("appearance", Context.MODE_PRIVATE)

    var darkMode: Boolean?
        get() = values.all["darkMode"] as? Boolean
        set(value) {
            values.edit {
                if (value == null) remove("darkMode") else putBoolean("darkMode", value)
            }
            applyNightMode()
        }

    /** Hands the color mode to the system, which keeps it and draws the next starting window in it. */
    fun applyNightMode() {
        context.getSystemService(UiModeManager::class.java).setApplicationNightMode(when (darkMode) {
            null -> UiModeManager.MODE_NIGHT_AUTO
            true -> UiModeManager.MODE_NIGHT_YES
            false -> UiModeManager.MODE_NIGHT_NO
        })
    }

    /** Material You's colors from the phone's wallpaper in place of Slatrix's own. */
    var wallpaperColors: Boolean
        get() = values.getBoolean("wallpaperColors", false)
        set(value) { values.edit { putBoolean("wallpaperColors", value) } }

    /** How much larger or smaller than the phone's text size messages are set, on this phone only. */
    var messageScale: Float
        get() = values.getFloat("messageScale", 1f).takeIf { it in MessageScales } ?: 1f
        set(value) { values.edit { putFloat("messageScale", value) } }

    companion object {
        /** From 14 to 24 sp at the phone's default text size, in 2 sp steps. */
        val MessageScales = listOf(0.875f, 1f, 1.125f, 1.25f, 1.375f, 1.5f)
    }
}
