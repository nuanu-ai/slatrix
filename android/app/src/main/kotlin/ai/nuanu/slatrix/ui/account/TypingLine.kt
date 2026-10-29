package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow

/** Who is typing, at the conversation's end in the room its list keeps for it, as the Mac's line under the composer. */
@Composable
fun TypingLine(names: List<String>, modifier: Modifier = Modifier) {
    if (names.isEmpty()) return
    val label = when (names.size) {
        1 -> "${names[0]} is typing…"
        2 -> "${names[0]} and ${names[1]} are typing…"
        else -> "Several people are typing…"
    }
    Text(label, modifier.fillMaxWidth().height(UiMetrics.TypingLine).padding(horizontal = UiMetrics.GapLarge).wrapContentHeight()
        .semantics { liveRegion = LiveRegionMode.Polite },
        style = MaterialTheme.typography.bodySmall, color = SlatrixTheme.colors.textSecondary, maxLines = 1,
        overflow = TextOverflow.Ellipsis)
}
