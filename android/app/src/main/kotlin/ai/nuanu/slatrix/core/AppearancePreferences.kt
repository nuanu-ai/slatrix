package ai.nuanu.slatrix.core

import android.content.Context
import androidx.core.content.edit

class AppearancePreferences(context: Context) {
    private val values = context.getSharedPreferences("appearance", Context.MODE_PRIVATE)

    var darkMode: Boolean?
        get() = values.all["darkMode"] as? Boolean
        set(value) {
            values.edit {
                if (value == null) remove("darkMode") else putBoolean("darkMode", value)
            }
        }

    var paletteName: String?
        get() = values.getString("palette", null)
        set(value) { values.edit { putString("palette", value) } }
}
