package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.ui.graphics.Color

enum class SidebarPalette {
    Aubergine, Clementine, Banana, Jade, Lagoon, Barbra, Gray, MoodIndigo;

    val tokenName: String get() = name.replaceFirstChar { it.lowercase() }
}

object DesignTokens {
    fun colors(dark: Boolean, palette: SidebarPalette): Map<String, Color> = emptyMap()
    val fileColors: Map<String, Color> = emptyMap()
    val avatarColors: List<Color> = emptyList()
    val radii: Map<String, Int> = emptyMap()
}
