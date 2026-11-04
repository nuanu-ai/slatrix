package ai.nuanu.slatrix.ui.designsystem

import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.ZeroCornerSize
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat

class AppColors internal constructor(private val roles: Map<String, Color>, private val dark: Boolean) {
    val textPrimary = roles.getValue("textPrimary")
    val textBody = roles.getValue("textBody")
    val textSecondary = roles.getValue("textSecondary")
    val textTertiary = roles.getValue("textTertiary")
    val canvas = roles.getValue("canvas")
    /** Search bars and other fields set into the canvas. */
    val raised = roles.getValue("raised")
    val sunken = roles.getValue("sunken")
    /** Sheets and dialogs. */
    val overlay = roles.getValue("overlay")
    /** The composer's field, floating over the wallpaper. */
    val field = roles.getValue("field")
    val tooltip = roles.getValue("tooltip")
    val onTooltip = roles.getValue("onTooltip")
    val scrim = roles.getValue("scrim")
    val border = roles.getValue("border")
    val borderStrong = roles.getValue("borderStrong")
    val hover = roles.getValue("hover")
    val pressed = roles.getValue("pressed")
    val highlight = roles.getValue("highlight")
    /** The accent as text and icons; [accentFill] is the same hue for filled shapes under [onAccent]. */
    val accent = roles.getValue("accent")
    val accentTint = roles.getValue("accentTint")
    val accentFill = roles.getValue("accentFill")
    val onAccent = roles.getValue("onAccent")
    val destructive = roles.getValue("destructive")
    val warning = roles.getValue("warning")
    /** A mention count's badge. */
    val mention = roles.getValue("mention")
    val mentionText = roles.getValue("mentionText")
    val mentionFill = roles.getValue("mentionFill")
    val mentionYouText = roles.getValue("mentionYouText")
    val mentionYouFill = roles.getValue("mentionYouFill")
    val presenceActive = roles.getValue("presenceActive")
    val presenceAway = roles.getValue("presenceAway")
    /** The chat wallpaper: a diagonal wash through three colors under a grid of faint dots. */
    val wallpaperTop = roles.getValue("wallpaperTop")
    val wallpaperMiddle = roles.getValue("wallpaperMiddle")
    val wallpaperBottom = roles.getValue("wallpaperBottom")
    val wallpaperDot = roles.getValue("wallpaperDot")
    /** Others' bubbles, lifted off the wallpaper by a hairline [bubbleEdge]; your own are [accentFill] under [onAccent]. */
    val bubbleIn = roles.getValue("bubbleIn")
    val bubbleEdge = roles.getValue("bubbleEdge")
    val bubbleOutMeta = roles.getValue("bubbleOutMeta")
    val bubbleOutRule = roles.getValue("bubbleOutRule")
    val reaction = roles.getValue("reaction")
    val dateChip = roles.getValue("dateChip")
    val onDateChip = roles.getValue("onDateChip")
    /** Frosted glass: the tab capsule's [glass] and the chat headers' [glassHeader], over a blur of what scrolls beneath. */
    val glass = roles.getValue("glass")
    val glassHeader = roles.getValue("glassHeader")
    val glassEdge = roles.getValue("glassEdge")
    val glassShadow = roles.getValue("glassShadow")
    val mediaBackdrop = roles.getValue("mediaBackdrop")
    val mediaControl = roles.getValue("mediaControl")
    val mediaShade = roles.getValue("mediaShade")
    val onMedia = roles.getValue("onMedia")
    val onMediaEdge = roles.getValue("onMediaEdge")
    // Text tints for message blocks, as the Mac draws them.
    val inlineCode = textBody.copy(alpha = 0.06f)
    val codeBlock = textBody.copy(alpha = 0.04f)
    val codeBlockEdge = textBody.copy(alpha = 0.16f)
    val quoteBar = textBody.copy(alpha = 0.25f)

    /** A person's color, from the shared avatar colors; in dark it is lightened so their name reads on a dark bubble. */
    fun person(colorIndex: Int): Color = DesignTokens.avatarColors[colorIndex].let { if (dark) lerp(it, Color.White, PersonLift) else it }

    /** The roles inside your own bubble, on [accentFill]: text, links and marks in [onAccent] and its quieter tints. */
    internal fun onFill(): AppColors {
        val on = roles.getValue("onAccent")
        val meta = roles.getValue("bubbleOutMeta")
        val rule = roles.getValue("bubbleOutRule")
        return AppColors(roles + mapOf(
            "textPrimary" to on, "textBody" to on, "textSecondary" to meta, "textTertiary" to meta, "border" to rule,
            "accent" to on, "accentTint" to rule, "accentFill" to rule, "mentionText" to on, "mentionFill" to rule,
            "mentionYouText" to on, "reaction" to rule, "bubbleIn" to roles.getValue("accentFill"),
        ), dark)
    }

    private companion object { const val PersonLift = 0.45f }
}

/** Draws [content] on the accent's fill, as your own bubbles are, with every role it reads turned to suit. */
@Composable
fun OnAccentFill(content: @Composable () -> Unit) {
    val colors = LocalColors.current
    val fill = remember(colors) { colors.onFill() }
    CompositionLocalProvider(LocalColors provides fill, LocalContentColor provides fill.textPrimary, content = content)
}

private val LocalColors = staticCompositionLocalOf { AppColors(DesignTokens.colors(false), false) }

/** Material You: the theme's surfaces and accent from the wallpaper, keeping the wallpaper wash pale under the bubbles. */
private fun wallpaperRoles(dark: Boolean, scheme: ColorScheme): Map<String, Color> {
    val wash = { color: Color -> lerp(scheme.surface, color, if (dark) 0.35f else 0.6f) }
    return DesignTokens.colors(dark) + mapOf(
        "textPrimary" to scheme.onSurface, "textBody" to scheme.onSurface, "textSecondary" to scheme.onSurfaceVariant,
        "canvas" to scheme.surface, "raised" to scheme.surfaceContainerHigh, "sunken" to scheme.surfaceContainerHighest,
        "overlay" to scheme.surfaceContainerLow, "border" to scheme.outlineVariant, "borderStrong" to scheme.outline,
        "accent" to scheme.primary, "accentTint" to scheme.primary.copy(alpha = 0.12f), "accentFill" to scheme.primary,
        "onAccent" to scheme.onPrimary, "mention" to scheme.primary, "mentionText" to scheme.primary,
        "mentionFill" to scheme.primary.copy(alpha = 0.12f), "wallpaperTop" to wash(scheme.primaryContainer),
        "wallpaperMiddle" to wash(scheme.secondaryContainer), "wallpaperBottom" to wash(scheme.tertiaryContainer),
        "wallpaperDot" to scheme.primary.copy(alpha = 0.08f),
        "bubbleIn" to if (dark) scheme.surfaceContainerHigh else scheme.surfaceContainerLowest,
        "reaction" to scheme.surfaceContainerHighest,
    )
}

object SlatrixTheme {
    val topPanelShape @Composable get() = MaterialTheme.shapes.extraLarge.copy(bottomStart = ZeroCornerSize, bottomEnd = ZeroCornerSize)
    val colors: AppColors @Composable get() = LocalColors.current
}

/** Slatrix's own theme, or with [wallpaperColors] Material You's colors from the phone's wallpaper. */
@Composable
fun SlatrixTheme(
    dark: Boolean = isSystemInDarkTheme(),
    wallpaperColors: Boolean = false,
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
    val context = LocalContext.current
    val colors = remember(dark, wallpaperColors, context) {
        AppColors(if (wallpaperColors) wallpaperRoles(dark, if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context))
            else DesignTokens.colors(dark), dark)
    }
    val scheme = remember(colors) {
        lightColorScheme(
            primary = colors.accentFill,
            onPrimary = colors.onAccent,
            primaryContainer = colors.accentTint,
            onPrimaryContainer = colors.accent,
            inversePrimary = colors.accent,
            secondary = colors.accent,
            onSecondary = colors.onAccent,
            secondaryContainer = colors.accentTint,
            onSecondaryContainer = colors.accent,
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
            onError = colors.onAccent,
            errorContainer = colors.mentionYouFill,
            onErrorContainer = colors.textPrimary,
            outline = colors.borderStrong,
            outlineVariant = colors.border,
            scrim = colors.scrim,
            surfaceBright = colors.canvas,
            surfaceContainer = colors.canvas,
            surfaceContainerHigh = colors.overlay,
            surfaceContainerHighest = colors.raised,
            surfaceContainerLow = colors.canvas,
            surfaceContainerLowest = colors.canvas,
            surfaceDim = colors.sunken,
        )
    }
    val shapes = remember {
        Shapes(
            extraSmall = RoundedCornerShape(DesignTokens.radii.getValue("extraSmall").dp),
            small = RoundedCornerShape(DesignTokens.radii.getValue("small").dp),
            medium = RoundedCornerShape(DesignTokens.radii.getValue("medium").dp),
            large = RoundedCornerShape(DesignTokens.radii.getValue("large").dp),
            extraLarge = RoundedCornerShape(DesignTokens.radii.getValue("extraLarge").dp),
        )
    }
    CompositionLocalProvider(LocalColors provides colors, LocalContentColor provides colors.textPrimary) {
        MaterialTheme(colorScheme = scheme, typography = SlatrixTypography, shapes = shapes, content = content)
    }
}
