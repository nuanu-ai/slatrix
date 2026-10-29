package ai.nuanu.slatrix.ui.designsystem

import ai.nuanu.slatrix.R
import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** Slack's typeface: Lato 2.015, under the SIL Open Font License that each file's name table carries. */
val Lato = FontFamily(
    Font(R.font.lato_regular),
    Font(R.font.lato_italic, style = FontStyle.Italic),
    Font(R.font.lato_bold, FontWeight.Bold),
    Font(R.font.lato_bold_italic, FontWeight.Bold, FontStyle.Italic),
    Font(R.font.lato_black, FontWeight.Black),
)

/** Material's sizes and line heights, set in Lato without Material's tracking, as Slack sets its text. */
internal val SlatrixTypography: Typography = Typography().run {
    fun TextStyle.lato() = copy(fontFamily = Lato, letterSpacing = 0.sp)
    Typography(
        displayLarge = displayLarge.lato(), displayMedium = displayMedium.lato(), displaySmall = displaySmall.lato(),
        headlineLarge = headlineLarge.lato(), headlineMedium = headlineMedium.lato(), headlineSmall = headlineSmall.lato(),
        titleLarge = titleLarge.lato(), titleMedium = titleMedium.lato(), titleSmall = titleMedium.lato(),
        bodyLarge = bodyLarge.lato(), bodyMedium = bodyMedium.lato(), bodySmall = bodySmall.lato(),
        labelLarge = labelLarge.lato(), labelMedium = labelMedium.lato(), labelSmall = labelSmall.lato(),
    )
}
