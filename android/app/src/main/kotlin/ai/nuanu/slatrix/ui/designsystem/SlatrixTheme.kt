package ai.nuanu.slatrix.ui.designsystem

import ai.nuanu.slatrix.core.AndroidTheme
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.ZeroCornerSize
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
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
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat

class AppColors internal constructor(private val roles: Map<String, Color>, private val dark: Boolean,
    /** Inside your own bubble links are underlined, since they share the text's color. */
    val underlineLinks: Boolean = false) {
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
    val tooltip = roles.getValue("tooltip")
    val onTooltip = roles.getValue("onTooltip")
    val scrim = roles.getValue("scrim")
    val border = roles.getValue("border")
    val borderStrong = roles.getValue("borderStrong")
    val highlight = roles.getValue("highlight")
    /** The accent as text and icons; [accentFill] is the same hue for filled shapes under [onAccent]. */
    val accent = roles.getValue("accent")
    val accentTint = roles.getValue("accentTint")
    val accentFill = roles.getValue("accentFill")
    val onAccent = roles.getValue("onAccent")
    /** Initials and icons on the shared avatar and file colors, whatever the accent. */
    val onAvatar = roles.getValue("onAvatar")
    val destructive = roles.getValue("destructive")
    val destructiveFill = roles.getValue("destructiveFill")
    val warning = roles.getValue("warning")
    /** Your own avatar's dot: filled while connected, a hollow ring once the connection is lost. */
    val presenceActive = roles.getValue("presenceActive")
    val presenceAway = roles.getValue("presenceAway")
    /** A mention count's badge. */
    val mention = roles.getValue("mention")
    val mentionText = roles.getValue("mentionText")
    val mentionFill = roles.getValue("mentionFill")
    val mentionYouText = roles.getValue("mentionYouText")
    val mentionYouFill = roles.getValue("mentionYouFill")
    /** The chat wallpaper: a calm cool gray under faint doodles of the app's own icons. */
    val wallpaper = roles.getValue("wallpaper")
    val wallpaperDoodle = roles.getValue("wallpaperDoodle")
    /** Others' bubbles on the wallpaper, borderless ([bubbleEdge] is transparent); your own are [accentFill] under [onAccent]. */
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
    val mediaShade = roles.getValue("mediaShade")
    val onMedia = roles.getValue("onMedia")
    // Text tints for message blocks, as the Mac draws them.
    val inlineCode = textBody.copy(alpha = 0.06f)
    val codeBlock = textBody.copy(alpha = 0.04f)
    val codeBlockEdge = textBody.copy(alpha = 0.16f)
    val quoteBar = textBody.copy(alpha = 0.25f)

    /** A person's color, from the shared avatar colors; in dark it is lightened so their name reads on a dark bubble. */
    fun person(colorIndex: Int): Color = DesignTokens.avatarColors[colorIndex].let { if (dark) lerp(it, Color.White, PersonLift) else it }

    /** Soft tinted container behind a file-type icon; on your own bubble uses the translucent bubble rule for contrast. */
    fun fileTileFill(color: Color): Color = if (underlineLinks) accentTint else color.copy(alpha = FileTileTintAlpha)

    /** Crisp file-type icon tint lifted in dark and shaded in light for WCAG contrast; uses [textPrimary] on your own bubble. */
    fun fileTileIcon(color: Color): Color = when {
        underlineLinks -> textPrimary
        dark -> lerp(color, Color.White, FileIconDarkLift)
        else -> lerp(color, Color.Black, FileIconLightShade)
    }

    /** The roles inside your own bubble, on [accentFill]: text, links and marks in [onAccent] and its quieter tints. */
    internal val onFill: AppColors by lazy {
        val on = roles.getValue("onAccent")
        val meta = roles.getValue("bubbleOutMeta")
        val rule = roles.getValue("bubbleOutRule")
        AppColors(roles + mapOf(
            "textPrimary" to on, "textBody" to on, "textSecondary" to meta, "textTertiary" to meta, "border" to rule,
            "accent" to on, "accentTint" to rule, "accentFill" to rule, "mentionText" to on, "mentionFill" to rule,
            "mentionYouText" to on, "reaction" to rule, "bubbleIn" to roles.getValue("accentFill"),
        ), dark, underlineLinks = true)
    }

    private companion object {
        const val PersonLift = 0.45f
        const val FileTileTintAlpha = 0.14f
        const val FileIconDarkLift = 0.38f
        const val FileIconLightShade = 0.18f
    }
}

/** Draws [content] on the accent's fill, as your own bubbles are, with every role it reads turned to suit. */
@Composable
fun OnAccentFill(content: @Composable () -> Unit) {
    val fill = LocalColors.current.onFill
    // Material's own components, such as progress indicators, draw in the scheme's primary, which is the bubble's fill.
    val scheme = MaterialTheme.colorScheme.copy(primary = fill.textPrimary, secondaryContainer = fill.border, surfaceVariant = fill.border)
    CompositionLocalProvider(LocalColors provides fill, LocalContentColor provides fill.textPrimary) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}

private val LocalColors = staticCompositionLocalOf { AppColors(DesignTokens.colors(false), false) }
private val LocalChatWallpaper = staticCompositionLocalOf { true }

/** Material You: the theme's surfaces and accent from the phone's wallpaper, washed into the chat backdrop. */
private fun wallpaperRoles(dark: Boolean, scheme: ColorScheme): Map<String, Color> {
    val wallpaperBase = if (dark) scheme.surfaceContainerLowest else scheme.surfaceContainer
    val wash = if (dark) WashAccentDark else WashAccentLight
    return DesignTokens.colors(AndroidTheme.Neutral, dark) + mapOf(
        "textPrimary" to scheme.onSurface,
        "textBody" to scheme.onSurface,
        "textSecondary" to scheme.onSurfaceVariant,
        "textTertiary" to scheme.onSurfaceVariant,
        "presenceAway" to scheme.onSurfaceVariant,
        "canvas" to scheme.surface,
        "raised" to scheme.surfaceContainerHigh,
        "sunken" to if (dark) scheme.surfaceContainerLowest else scheme.surfaceContainerLow,
        "overlay" to if (dark) scheme.surfaceContainerHighest else scheme.surfaceContainerLowest,
        "border" to scheme.outlineVariant,
        "borderStrong" to scheme.outline,
        "accent" to scheme.primary,
        "accentTint" to scheme.primary.copy(alpha = 0.12f),
        "accentFill" to scheme.primary,
        "onAccent" to scheme.onPrimary,
        "destructive" to scheme.error,
        "destructiveFill" to scheme.error,
        "mention" to scheme.primary,
        "mentionText" to scheme.primary,
        "mentionFill" to scheme.primary.copy(alpha = 0.12f),
        "wallpaper" to lerp(wallpaperBase, scheme.primary, wash),
        "wallpaperDoodle" to if (dark) scheme.onSurface.copy(alpha = 0.045f) else scheme.primary.copy(alpha = 0.07f),
        "bubbleOutMeta" to scheme.onPrimary.copy(alpha = 0.9f),
        "bubbleOutRule" to scheme.onPrimary.copy(alpha = 0.22f),
        "bubbleIn" to if (dark) scheme.surfaceContainerHigh else scheme.surfaceContainerLowest,
        "reaction" to scheme.surfaceContainerHighest,
        "onDateChip" to if (dark) scheme.onSurface else scheme.onSurfaceVariant,
        "glass" to (if (dark) scheme.surfaceContainerHigh else scheme.surfaceContainerLowest).copy(alpha = if (dark) 0.58f else 0.66f),
        "glassHeader" to (if (dark) scheme.surface else scheme.surfaceContainerLowest).copy(alpha = if (dark) 0.66f else 0.76f),
        "glassEdge" to scheme.onSurface.copy(alpha = if (dark) 0.07f else 0.09f),
    )
}

/** Boosts borders, text, and surface separation for any theme while keeping borderless bubbles and WCAG AA contrast. */
private fun applyHighContrast(base: Map<String, Color>, dark: Boolean): Map<String, Color> {
    val accentFillBase = base.getValue("accentFill")
    val onAccentBase = base.getValue("onAccent")
    val destructiveFillBase = base.getValue("destructiveFill")
    val lightOnFill = onAccentBase.luminance() >= accentFillBase.luminance()
    val accentFill = if (lightOnFill) lerp(accentFillBase, Color.Black, if (dark) 0.16f else 0.22f) else lerp(accentFillBase, Color.White, 0.25f)
    val onAccent = if (lightOnFill) Color.White else lerp(onAccentBase, Color.Black, 0.5f)
    val destructiveFill = if (lightOnFill) lerp(destructiveFillBase, Color.Black, if (dark) 0.16f else 0.22f) else lerp(destructiveFillBase, Color.White, 0.22f)

    val adjustments = if (dark) {
        val boostedAccent = lerp(base.getValue("accent"), Color.White, 0.32f)
        mapOf(
            "sunken" to Color.Black,
            "canvas" to Color.Black,
            "raised" to lerp(base.getValue("raised"), Color.Black, 0.14f),
            "overlay" to lerp(base.getValue("overlay"), Color.Black, 0.08f),
            "textPrimary" to Color.White,
            "textBody" to Color.White,
            "textSecondary" to lerp(base.getValue("textSecondary"), Color.White, 0.45f),
            "textTertiary" to lerp(base.getValue("textTertiary"), Color.White, 0.45f),
            "presenceAway" to lerp(base.getValue("presenceAway"), Color.White, 0.45f),
            "border" to lerp(base.getValue("border"), Color.White, 0.38f),
            "borderStrong" to lerp(base.getValue("borderStrong"), Color.White, 0.52f),
            "glassEdge" to Color.White.copy(alpha = 0.3f),
            "glass" to base.getValue("glass").copy(alpha = maxOf(base.getValue("glass").alpha, 0.8f)),
            "glassHeader" to base.getValue("glassHeader").copy(alpha = maxOf(base.getValue("glassHeader").alpha, 0.86f)),
            "wallpaper" to lerp(base.getValue("wallpaper"), Color.Black, 0.75f),
            "bubbleIn" to lerp(base.getValue("bubbleIn"), Color.Black, 0.1f),
            "reaction" to lerp(base.getValue("reaction"), Color.White, 0.06f),
            "dateChip" to Color.Black.copy(alpha = 0.75f),
            "onDateChip" to Color.White,
            "accent" to boostedAccent,
            "mentionText" to boostedAccent,
            "accentTint" to base.getValue("accent").copy(alpha = 0.22f),
            "mentionFill" to base.getValue("accent").copy(alpha = 0.18f),
            "destructive" to lerp(base.getValue("destructive"), Color.White, 0.22f),
            "warning" to lerp(base.getValue("warning"), Color.White, 0.22f),
            "mentionYouText" to lerp(base.getValue("mentionYouText"), Color.White, 0.28f),
            "mentionYouFill" to base.getValue("mentionYouFill").copy(alpha = 0.2f),
        )
    } else {
        val boostedAccent = lerp(base.getValue("accent"), Color.Black, 0.24f)
        mapOf(
            "canvas" to Color.White,
            "overlay" to Color.White,
            "raised" to lerp(base.getValue("raised"), Color.Black, 0.03f),
            "sunken" to lerp(base.getValue("sunken"), Color.Black, 0.06f),
            "textPrimary" to Color.Black,
            "textBody" to Color.Black,
            "textSecondary" to lerp(base.getValue("textSecondary"), Color.Black, 0.45f),
            "textTertiary" to lerp(base.getValue("textTertiary"), Color.Black, 0.45f),
            "presenceAway" to lerp(base.getValue("presenceAway"), Color.Black, 0.45f),
            "border" to lerp(base.getValue("border"), Color.Black, 0.38f),
            "borderStrong" to lerp(base.getValue("borderStrong"), Color.Black, 0.52f),
            "glassEdge" to Color.Black.copy(alpha = 0.28f),
            "glass" to base.getValue("glass").copy(alpha = maxOf(base.getValue("glass").alpha, 0.86f)),
            "glassHeader" to base.getValue("glassHeader").copy(alpha = maxOf(base.getValue("glassHeader").alpha, 0.9f)),
            "wallpaper" to lerp(base.getValue("wallpaper"), Color.Black, 0.07f),
            "bubbleIn" to Color.White,
            "reaction" to lerp(base.getValue("reaction"), Color.Black, 0.05f),
            "dateChip" to Color.White.copy(alpha = 0.92f),
            "onDateChip" to Color.Black,
            "accent" to boostedAccent,
            "mentionText" to boostedAccent,
            "accentTint" to boostedAccent.copy(alpha = 0.15f),
            "mentionFill" to boostedAccent.copy(alpha = 0.15f),
            "destructive" to lerp(base.getValue("destructive"), Color.Black, 0.24f),
            "warning" to lerp(base.getValue("warning"), Color.Black, 0.25f),
            "mentionYouText" to lerp(base.getValue("mentionYouText"), Color.Black, 0.3f),
            "mentionYouFill" to base.getValue("mentionYouFill").copy(alpha = 0.4f),
        )
    }
    return base + adjustments + mapOf(
        "accentFill" to accentFill,
        "mention" to accentFill,
        "onAccent" to onAccent,
        "destructiveFill" to destructiveFill,
        "bubbleOutMeta" to onAccent.copy(alpha = 0.96f),
        "bubbleOutRule" to onAccent.copy(alpha = 0.36f),
    )
}

internal fun themeRoles(
    theme: AndroidTheme,
    dark: Boolean,
    increaseContrast: Boolean = false,
    dynamicScheme: ColorScheme? = null,
): Map<String, Color> {
    val base = if (theme == AndroidTheme.MaterialYou && dynamicScheme != null) {
        wallpaperRoles(dark, dynamicScheme)
    } else {
        DesignTokens.colors(theme, dark)
    }
    return if (increaseContrast) applyHighContrast(base, dark) else base
}

private const val WashAccentLight = 0.05f
private const val WashAccentDark = 0.03f

object SlatrixTheme {
    val topPanelShape @Composable get() = MaterialTheme.shapes.extraLarge.copy(bottomStart = ZeroCornerSize, bottomEnd = ZeroCornerSize)
    val colors: AppColors @Composable get() = LocalColors.current
    val chatWallpaper: Boolean @Composable get() = LocalChatWallpaper.current
}

/** Slatrix's theme system: 6 curated palettes (including Material You), independent chat wallpaper, and high contrast. */
@Composable
fun SlatrixTheme(
    dark: Boolean = isSystemInDarkTheme(),
    theme: AndroidTheme = AndroidTheme.Neutral,
    chatWallpaper: Boolean = true,
    increaseContrast: Boolean = false,
    messageScale: Float = 1f,
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
    val colors = remember(dark, theme, increaseContrast, context) {
        val dynamic = if (theme == AndroidTheme.MaterialYou) {
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        } else null
        AppColors(themeRoles(theme, dark, increaseContrast, dynamic), dark)
    }
    val scheme = remember(colors, dark) {
        val base = if (dark) darkColorScheme() else lightColorScheme()
        base.copy(
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
            surfaceBright = colors.overlay,
            surfaceContainer = colors.canvas,
            surfaceContainerHigh = colors.raised,
            surfaceContainerHighest = colors.overlay,
            surfaceContainerLow = colors.sunken,
            surfaceContainerLowest = colors.sunken,
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
    CompositionLocalProvider(
        LocalColors provides colors,
        LocalContentColor provides colors.textPrimary,
        LocalMessageScale provides messageScale,
        LocalChatWallpaper provides chatWallpaper,
    ) {
        MaterialTheme(colorScheme = scheme, typography = SlatrixTypography, shapes = shapes, content = content)
    }
}
