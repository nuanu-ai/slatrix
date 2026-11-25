package ai.nuanu.slatrix.ui.designsystem

import ai.nuanu.slatrix.core.AndroidTheme
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/** Lays out a group of theme swatches in 3 columns when labels fit, dropping to 2 columns on narrow screens at large text sizes. */
@Composable
fun ThemeSwatchRow(
    choices: List<AndroidTheme>,
    selected: AndroidTheme,
    dark: Boolean,
    increaseContrast: Boolean,
    onSelect: (AndroidTheme) -> Unit,
    modifier: Modifier = Modifier,
) {
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold)
    val widestWord = remember(choices, measurer, style, density) {
        with(density) {
            choices.flatMap { it.label.split(' ') }
                .maxOf { measurer.measure(it, style).size.width }
                .toDp()
        }
    }
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val threeColWidth = (maxWidth - UiMetrics.GapSmall * 2) / 3
        val twoColWidth = (maxWidth - UiMetrics.GapSmall) / 2
        val needed = widestWord + LabelInsetHorizontal * 2
        val columns = when {
            threeColWidth >= needed -> 3
            twoColWidth >= needed -> 2
            else -> 1
        }
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
            choices.chunked(columns).forEach { rowChoices ->
                Row(
                    Modifier.fillMaxWidth().height(IntrinsicSize.Max),
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall),
                ) {
                    rowChoices.forEach { choice ->
                        ThemeSwatch(choice, selected == choice, dark, increaseContrast, { onSelect(choice) },
                            Modifier.weight(1f).fillMaxHeight())
                    }
                    repeat(columns - rowChoices.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

/** A palette preview card showing a theme's wallpaper, incoming bubble, outgoing accent bubble, and label. */
@Composable
fun ThemeSwatch(
    choice: AndroidTheme,
    selected: Boolean,
    dark: Boolean,
    increaseContrast: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = SlatrixTheme.colors
    val context = LocalContext.current
    val preview = remember(choice, dark, increaseContrast, context) {
        val dynamic = if (choice == AndroidTheme.MaterialYou) {
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        } else null
        AppColors(themeRoles(choice, dark, increaseContrast, dynamic), dark)
    }
    val shape = MaterialTheme.shapes.medium
    val borderWidth = if (selected) SelectedBorder else UiMetrics.Divider
    val borderColor = if (selected) colors.accent else colors.border
    val bubbleShape = MaterialTheme.shapes.small

    Column(
        modifier
            .clip(shape)
            .background(colors.raised)
            .border(borderWidth, borderColor, shape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(PreviewHeight)
                .background(preview.wallpaper)
                .padding(PreviewInset),
        ) {
            Column(
                Modifier.fillMaxWidth().align(Alignment.Center),
                verticalArrangement = Arrangement.spacedBy(PreviewGap),
            ) {
                Box(
                    Modifier
                        .fillMaxWidth(0.58f)
                        .height(PreviewBubbleHeight)
                        .clip(bubbleShape)
                        .background(preview.bubbleIn),
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    Box(
                        Modifier
                            .fillMaxWidth(0.52f)
                            .height(PreviewBubbleHeight)
                            .clip(bubbleShape)
                            .background(preview.accentFill),
                    )
                }
            }
            if (selected) {
                Box(
                    Modifier
                        .align(Alignment.TopEnd)
                        .size(CheckBadge)
                        .clip(CircleShape)
                        .background(colors.accentFill),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(SlackIcons.Check, null, Modifier.size(CheckIcon), tint = colors.onAccent)
                }
            }
        }
        Box(
            Modifier
                .fillMaxWidth()
                .fillMaxHeight()
                .padding(horizontal = LabelInsetHorizontal, vertical = LabelInsetVertical),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                choice.label,
                Modifier.fillMaxWidth(),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                color = if (selected) colors.accent else colors.textPrimary,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

private val SelectedBorder = 2.dp
private val PreviewHeight = 52.dp
private val PreviewInset = 8.dp
private val PreviewGap = 5.dp
private val PreviewBubbleHeight = 11.dp
private val CheckBadge = 18.dp
private val CheckIcon = 12.dp
private val LabelInsetHorizontal = 6.dp
private val LabelInsetVertical = 8.dp
