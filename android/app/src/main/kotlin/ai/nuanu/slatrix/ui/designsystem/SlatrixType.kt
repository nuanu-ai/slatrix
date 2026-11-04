package ai.nuanu.slatrix.ui.designsystem

import ai.nuanu.slatrix.R
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.material3.Typography
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * Roboto, the boards' face, carried in the app: a phone whose system font is another, as a OnePlus's is, would set
 * every line in different metrics. One variable font holds each weight and its italic.
 */
@OptIn(ExperimentalTextApi::class)
private val Roboto = FontFamily(listOf(FontWeight.Normal, FontWeight.Medium, FontWeight.SemiBold, FontWeight.Bold, FontWeight.Black)
    .flatMap { weight ->
        listOf(FontStyle.Normal, FontStyle.Italic).map { style ->
            Font(R.font.roboto, weight, style, variationSettings = FontVariation.Settings(
                FontVariation.weight(weight.weight), FontVariation.italic(if (style == FontStyle.Italic) 1f else 0f)))
        }
    })

/**
 * Material 3's type scale in Roboto, in sp, so it grows with the phone's font size. Set without Material's extra
 * tracking, as the boards and the messengers they follow set it; spaced out, small text on a narrow phone reads loose.
 */
internal val SlatrixTypography = Typography().run {
    fun TextStyle.set() = copy(fontFamily = Roboto, letterSpacing = 0.sp)
    Typography(displayLarge.set(), displayMedium.set(), displaySmall.set(), headlineLarge.set(), headlineMedium.set(),
        headlineSmall.set(), titleLarge.set(), titleMedium.set(), titleSmall.set(), bodyLarge.set(), bodyMedium.set(),
        bodySmall.set(), labelLarge.set(), labelMedium.set(), labelSmall.set())
}

/** How much the chosen message text size scales message text, on top of the phone's own font size. */
val LocalMessageScale = compositionLocalOf { 1f }

/**
 * A message's text: body large with a messenger's tighter leading, so a long message reads as one block in its bubble,
 * at the chosen message text size.
 */
val Typography.message: TextStyle
    @Composable get() = LocalMessageScale.current.let { bodyLarge.copy(fontSize = bodyLarge.fontSize * it, lineHeight = 22.sp * it) }

/** A tab's label, shrinking to as little as two thirds of its size where a large font won't let it fit. */
val Typography.tabFit: TextAutoSize get() = TextAutoSize.StepBased(minFontSize = labelSmall.fontSize * 2 / 3, maxFontSize = labelSmall.fontSize)
