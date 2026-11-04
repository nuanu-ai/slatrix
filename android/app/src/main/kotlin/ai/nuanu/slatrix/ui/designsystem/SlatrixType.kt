package ai.nuanu.slatrix.ui.designsystem

import ai.nuanu.slatrix.R
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

/** A message's text: body large with a messenger's tighter leading, so a long message reads as one block in its bubble. */
val Typography.message: TextStyle get() = bodyLarge.copy(lineHeight = 22.sp)
