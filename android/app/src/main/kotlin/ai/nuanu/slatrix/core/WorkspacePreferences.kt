package ai.nuanu.slatrix.core

import android.content.Context
import androidx.core.content.edit

class WorkspacePreferences(context: Context, userId: String) {
    private val values = context.getSharedPreferences("workspaces", Context.MODE_PRIVATE)
    private val key = userId
    var selectedSpaceId: String?
        get() = values.getString(key, null)
        set(value) { values.edit { if (value == null) remove(key) else putString(key, value) } }
}
