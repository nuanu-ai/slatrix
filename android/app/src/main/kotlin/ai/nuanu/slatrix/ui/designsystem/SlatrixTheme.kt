package ai.nuanu.slatrix.ui.designsystem

import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.ZeroCornerSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Shapes
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat

class AppColors internal constructor(
    roles: Map<String, Color>,
    /** The workspace color root headers sit on; Slack keeps it in light mode too, under white text. */
    val workspaceBar: Color,
) {
    val textPrimary = roles.getValue("textPrimary")
    val textBody = roles.getValue("textBody")
    val textSecondary = roles.getValue("textSecondary")
    val textTertiary = roles.getValue("textTertiary")
    val canvas = roles.getValue("canvas")
    val raised = roles.getValue("raised")
    val sunken = roles.getValue("sunken")
    val overlay = roles.getValue("overlay")
    val tooltip = roles.getValue("tooltip")
    val onTooltip = roles.getValue("onTooltip")
    val scrim = roles.getValue("scrim")
    val sidebar = roles.getValue("sidebar")
    val frame = roles.getValue("frame")
    val border = roles.getValue("border")
    val borderStrong = roles.getValue("borderStrong")
    val hover = roles.getValue("hover")
    val pressed = roles.getValue("pressed")
    val selection = roles.getValue("selection")
    val selectionStrong = roles.getValue("selectionStrong")
    val selectionText = roles.getValue("selectionText")
    val highlight = roles.getValue("highlight")
    val focusRing = roles.getValue("focusRing")
    val accent = roles.getValue("accent")
    val accentTint = roles.getValue("accentTint")
    val onAccent = roles.getValue("onAccent")
    val buttonPrimary = roles.getValue("buttonPrimary")
    val success = roles.getValue("success")
    val destructive = roles.getValue("destructive")
    val warning = roles.getValue("warning")
    val mention = roles.getValue("mention")
    val mentionText = roles.getValue("mentionText")
    val mentionFill = roles.getValue("mentionFill")
    val mentionYouText = roles.getValue("mentionYouText")
    val mentionYouFill = roles.getValue("mentionYouFill")
    val presenceActive = roles.getValue("presenceActive")
    val presenceAway = roles.getValue("presenceAway")
    val mediaBackdrop = roles.getValue("mediaBackdrop")
    val mediaControl = roles.getValue("mediaControl")
    val mediaShade = roles.getValue("mediaShade")
    val onMedia = roles.getValue("onMedia")
    val onMediaEdge = roles.getValue("onMediaEdge")
    // Text tints for message blocks, as the Mac draws them.
    val inlineCode = textBody.copy(alpha = 0.07f)
    val codeBlock = textBody.copy(alpha = 0.04f)
    val codeBlockEdge = textBody.copy(alpha = 0.16f)
    val quoteBar = textBody.copy(alpha = 0.25f)
}

private val LocalColors = staticCompositionLocalOf { appColors(false, SidebarPalette.Aubergine) }
private val LocalDark = staticCompositionLocalOf { false }

private fun appColors(dark: Boolean, palette: SidebarPalette) =
    AppColors(DesignTokens.colors(dark, palette), DesignTokens.colors(true, palette).getValue("frame"))

/** Keeps status bar icons light while the workspace color sits behind them, and hands them back to the theme after. */
@Composable
fun StatusBarOverWorkspaceBar() {
    val window = LocalActivity.current?.window ?: return
    val dark by rememberUpdatedState(LocalDark.current)
    // Runs after the theme's own SideEffect, which sets the icons for the canvas.
    SideEffect { WindowCompat.getInsetsController(window, window.decorView).isAppearanceLightStatusBars = false }
    DisposableEffect(window) {
        onDispose { WindowCompat.getInsetsController(window, window.decorView).isAppearanceLightStatusBars = !dark }
    }
}

object SlatrixTheme {
    val topPanelShape @Composable get() = MaterialTheme.shapes.extraLarge.copy(bottomStart = ZeroCornerSize, bottomEnd = ZeroCornerSize)
    val colors: AppColors @Composable get() = LocalColors.current
}

@Composable
fun SlatrixTheme(
    dark: Boolean = isSystemInDarkTheme(),
    palette: SidebarPalette = SidebarPalette.Aubergine,
    content: @Composable () -> Unit,
) {
    val activity = LocalActivity.current
    SideEffect {
        activity?.window?.let { window ->
            WindowCompat.getInsetsController(window, window.decorView).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }
    }
    val colors = remember(dark, palette) { appColors(dark, palette) }
    val scheme = remember(colors) {
        lightColorScheme(
            primary = colors.accent,
            onPrimary = colors.onAccent,
            primaryContainer = colors.accentTint,
            onPrimaryContainer = colors.textPrimary,
            inversePrimary = colors.accent,
            secondary = colors.buttonPrimary,
            onSecondary = colors.onAccent,
            secondaryContainer = colors.selection,
            onSecondaryContainer = colors.textPrimary,
            tertiary = colors.mentionText,
            onTertiary = colors.onAccent,
            tertiaryContainer = colors.mentionFill,
            onTertiaryContainer = colors.mentionText,
            background = colors.canvas,
            onBackground = colors.textBody,
            surface = colors.canvas,
            onSurface = colors.textPrimary,
            surfaceVariant = colors.raised,
            onSurfaceVariant = colors.textSecondary,
            surfaceTint = colors.accent,
            inverseSurface = colors.tooltip,
            inverseOnSurface = colors.onTooltip,
            error = colors.destructive,
            onError = colors.selectionText,
            errorContainer = colors.mentionYouFill,
            onErrorContainer = colors.textPrimary,
            outline = colors.borderStrong,
            outlineVariant = colors.border,
            scrim = colors.scrim,
            surfaceBright = colors.raised,
            surfaceContainer = colors.raised,
            surfaceContainerHigh = colors.overlay,
            surfaceContainerHighest = colors.sunken,
            surfaceContainerLow = colors.raised,
            surfaceContainerLowest = colors.canvas,
            surfaceDim = colors.sunken,
        )
    }
    val shapes = remember {
        Shapes(
            extraSmall = RoundedCornerShape(DesignTokens.radii.getValue("small").dp),
            small = RoundedCornerShape(DesignTokens.radii.getValue("small").dp),
            medium = RoundedCornerShape(DesignTokens.radii.getValue("default").dp),
            large = RoundedCornerShape(DesignTokens.radii.getValue("large").dp),
            extraLarge = RoundedCornerShape(DesignTokens.radii.getValue("panel").dp),
        )
    }
    CompositionLocalProvider(LocalColors provides colors, LocalDark provides dark, LocalContentColor provides colors.textPrimary) {
        MaterialTheme(colorScheme = scheme, typography = SlatrixTypography, shapes = shapes, content = content)
    }
}
