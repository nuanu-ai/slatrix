package ai.nuanu.slatrix.ui.designsystem

import ai.nuanu.slatrix.core.AndroidTheme
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

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
    val bubbleRadius = RoundedCornerShape(PreviewBubbleRadius)

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
                        .clip(bubbleRadius)
                        .background(preview.bubbleIn),
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    Box(
                        Modifier
                            .fillMaxWidth(0.52f)
                            .height(PreviewBubbleHeight)
                            .clip(bubbleRadius)
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
        Text(
            choice.label,
            Modifier
                .fillMaxWidth()
                .padding(horizontal = LabelInsetHorizontal, vertical = LabelInsetVertical),
            style = MaterialTheme.typography.labelMedium,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
            color = if (selected) colors.accent else colors.textPrimary,
            textAlign = TextAlign.Center,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            autoSize = MaterialTheme.typography.tabFit,
        )
    }
}

private val SelectedBorder = 2.dp
private val PreviewHeight = 52.dp
private val PreviewInset = 8.dp
private val PreviewGap = 5.dp
private val PreviewBubbleHeight = 11.dp
private val PreviewBubbleRadius = 6.dp
private val CheckBadge = 18.dp
private val CheckIcon = 12.dp
private val LabelInsetHorizontal = 6.dp
private val LabelInsetVertical = 8.dp
