package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow

/**
 * Who is typing, on a line of its own over the composer, as the Mac's under it. The line is always there, one line of
 * its text tall, so it comes and goes without moving a message.
 */
@Composable
fun TypingLine(names: List<String>) {
    val label = when (names.size) {
        0 -> ""
        1 -> "${names[0]} is typing…"
        2 -> "${names[0]} and ${names[1]} are typing…"
        else -> "Several people are typing…"
    }
    Text(label, Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge).semantics { liveRegion = LiveRegionMode.Polite },
        style = MaterialTheme.typography.bodySmall, color = SlatrixTheme.colors.textSecondary, maxLines = 1, minLines = 1,
        overflow = TextOverflow.Ellipsis)
}
