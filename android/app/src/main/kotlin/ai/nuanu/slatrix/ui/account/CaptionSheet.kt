package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.caption
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow

/** Edits your media's caption, as the Mac's caption editor does; saving it empty removes it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CaptionSheet(message: ConversationMessage, onSave: (String?) -> Unit, onDismiss: () -> Unit) {
    val colors = SlatrixTheme.colors
    var caption by rememberSaveable(message.id) { mutableStateOf(message.caption.orEmpty()) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        shape = SlatrixTheme.topPanelShape, containerColor = colors.canvas) {
        Column(Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge).padding(bottom = UiMetrics.GapLarge),
            verticalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Edit caption", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    Text(message.attachment?.name.orEmpty(), style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary,
                        maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
                }
                TextButton(onClick = { onSave(caption.trim().ifEmpty { null }) },
                    enabled = caption.trim().ifEmpty { null } != message.caption) { Text("Save") }
            }
            OutlinedTextField(caption, { caption = it }, Modifier.fillMaxWidth(), label = { Text("Caption") }, maxLines = 6)
        }
    }
}
