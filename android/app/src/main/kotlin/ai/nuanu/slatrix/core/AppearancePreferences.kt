package ai.nuanu.slatrix.core

import android.app.UiModeManager
import android.content.Context
import androidx.core.content.edit
import org.json.JSONObject

enum class AndroidTheme(val key: String, val label: String, val colored: Boolean) {
    Neutral("neutral", "Neutral", colored = false),
    MaterialYou("materialYou", "Material You", colored = false),
    Sand("sand", "Sand", colored = false),
    Aubergine("aubergine", "Aubergine", colored = true),
    Jade("jade", "Jade", colored = true),
    Ocean("ocean", "Ocean", colored = true);

    companion object {
        fun fromKey(key: String?): AndroidTheme? = entries.firstOrNull { it.key == key }
    }
}

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

    /** Chosen palette for all workspaces; migrates legacy `wallpaperColors = true` to [AndroidTheme.MaterialYou]. */
    var theme: AndroidTheme
        get() {
            val all = values.all
            if ("theme" in all) return AndroidTheme.fromKey(all["theme"] as? String) ?: AndroidTheme.Neutral
            return if (all["wallpaperColors"] as? Boolean == true) AndroidTheme.MaterialYou else AndroidTheme.Neutral
        }
        set(value) {
            values.edit {
                putString("theme", value.key)
                remove("wallpaperColors")
            }
        }

    /** Whether conversations draw the faint doodle pattern over their wallpaper tint. */
    var chatWallpaper: Boolean
        get() = values.all["chatWallpaper"] as? Boolean ?: true
        set(value) { values.edit { putBoolean("chatWallpaper", value) } }

    /** Strengthens borders, text, and surface separation on any theme. */
    var increaseContrast: Boolean
        get() = values.all["increaseContrast"] as? Boolean ?: false
        set(value) { values.edit { putBoolean("increaseContrast", value) } }

    /** Per-workspace theme overrides keyed by Matrix space ID. */
    val workspaceThemes: Map<String, AndroidTheme>
        get() {
            val stored = values.all["workspaceThemes"] as? String ?: return emptyMap()
            return runCatching {
                val json = JSONObject(stored)
                buildMap {
                    val keys = json.keys()
                    while (keys.hasNext()) {
                        val id = keys.next()
                        if (id.isBlank()) continue
                        val parsed = AndroidTheme.fromKey(json.opt(id) as? String)
                        if (parsed != null) put(id, parsed)
                    }
                }
            }.getOrElse { emptyMap() }
        }

    /** Resolves [workspaceId]'s override when set, otherwise the global [theme]. */
    fun effectiveTheme(workspaceId: String?): AndroidTheme =
        workspaceId?.let { workspaceThemes[it] } ?: theme

    /** Sets a per-workspace theme override, or clears it back to the global default when [theme] is null. */
    fun setWorkspaceTheme(workspaceId: String, theme: AndroidTheme?) {
        if (workspaceId.isBlank()) return
        val updated = workspaceThemes.toMutableMap()
        if (theme == null) updated.remove(workspaceId) else updated[workspaceId] = theme
        values.edit {
            if (updated.isEmpty()) {
                remove("workspaceThemes")
            } else {
                val json = JSONObject()
                updated.forEach { (id, choice) -> json.put(id, choice.key) }
                putString("workspaceThemes", json.toString())
            }
        }
    }

    /** How much larger or smaller than the phone's text size messages are set, on this phone only. */
    var messageScale: Float
        get() = values.getFloat("messageScale", 1f).takeIf { it in MessageScales } ?: 1f
        set(value) { values.edit { putFloat("messageScale", value) } }

    companion object {
        /** From 14 to 24 sp at the phone's default text size, in 2 sp steps. */
        val MessageScales = listOf(0.875f, 1f, 1.125f, 1.25f, 1.375f, 1.5f)
    }
}
