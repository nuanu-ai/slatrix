package ai.nuanu.slatrix.ui.mockups

import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable

enum class MockScreen { Home, Dms, Activity, Channel, Thread, You }

@Composable
fun SlatrixMockups(
    initialScreen: MockScreen = MockScreen.Home,
    dark: Boolean = false,
    initialPalette: SidebarPalette = SidebarPalette.Aubergine,
) {
    SlatrixTheme(dark = dark, palette = initialPalette) { Text("Slatrix") }
}
