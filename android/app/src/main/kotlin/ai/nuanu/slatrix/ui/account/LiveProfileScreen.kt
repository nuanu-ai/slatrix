package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import androidx.compose.runtime.Composable

@Composable
fun LiveProfileScreen(
    userId: String,
    dark: Boolean,
    darkOverride: Boolean?,
    palette: SidebarPalette,
    onColorMode: (Boolean?) -> Unit,
    onPalette: (SidebarPalette) -> Unit,
    onBack: () -> Unit,
) {
}
