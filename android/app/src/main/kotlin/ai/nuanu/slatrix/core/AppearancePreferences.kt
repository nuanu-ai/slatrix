package ai.nuanu.slatrix.core

import android.app.UiModeManager
import android.content.Context
import android.os.Build
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
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        context.getSystemService(UiModeManager::class.java).setApplicationNightMode(when (darkMode) {
            null -> UiModeManager.MODE_NIGHT_AUTO
            true -> UiModeManager.MODE_NIGHT_YES
            false -> UiModeManager.MODE_NIGHT_NO
        })
    }

    var paletteName: String?
        get() = values.getString("palette", null)
        set(value) { values.edit { putString("palette", value) } }
}
