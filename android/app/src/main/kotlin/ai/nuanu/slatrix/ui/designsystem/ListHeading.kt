package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow

/** A section's title in a list, the same on every screen, so it stands apart from the rows under it. */
@Composable
fun ListHeading(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier.semantics { heading() }, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
        color = SlatrixTheme.colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
}
