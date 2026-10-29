package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.EmojiCatalog
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private sealed interface PickerItem {
    data class Header(val title: String) : PickerItem
    data class Glyph(val value: String, val name: String) : PickerItem
}

/** Slack's full emoji picker: search by shortcode or name above your recent emoji and every category. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun EmojiPickerSheet(recent: List<String>, onPick: (String) -> Unit, onDismiss: () -> Unit) {
    val colors = SlatrixTheme.colors
    val context = LocalContext.current
    val catalog by produceState<EmojiCatalog?>(null, context) { value = withContext(Dispatchers.IO) { EmojiCatalog.load(context) } }
    var query by remember { mutableStateOf("") }
    val items = remember(catalog, query, recent) {
        val all = catalog ?: return@remember emptyList()
        if (query.isNotBlank()) all.search(query).map { PickerItem.Glyph(it.value, it.name) }
        else buildList<PickerItem> {
            val frequent = recent.mapNotNull { value -> all.emoji(value)?.let { PickerItem.Glyph(value, it.name) } }
            if (frequent.isNotEmpty()) { add(PickerItem.Header("Frequently used")); addAll(frequent) }
            all.all.groupBy { it.category }.forEach { (category, emoji) ->
                add(PickerItem.Header(category.title))
                emoji.mapTo(this) { PickerItem.Glyph(it.value, it.name) }
            }
        }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        shape = SlatrixTheme.topPanelShape, containerColor = colors.canvas) {
        Column(Modifier.fillMaxHeight()) {
            Surface(Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge), shape = MaterialTheme.shapes.medium,
                color = colors.raised) {
                Row(Modifier.heightIn(min = UiMetrics.Touch).padding(horizontal = UiMetrics.GapMedium),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.Search, null, Modifier.size(UiMetrics.Icon), tint = colors.textSecondary)
                    BasicTextField(query, { query = it }, Modifier.weight(1f).padding(start = UiMetrics.GapSmall)
                        .semantics { contentDescription = "Search emoji" },
                        textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.textBody),
                        cursorBrush = SolidColor(colors.accent), singleLine = true,
                        decorationBox = { inner ->
                            if (query.isEmpty()) Text("Search emoji", style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary)
                            inner()
                        })
                }
            }
            LazyVerticalGrid(GridCells.Adaptive(UiMetrics.Touch), Modifier.fillMaxWidth().weight(1f),
                contentPadding = PaddingValues(horizontal = UiMetrics.GapSmall,
                    vertical = UiMetrics.GapSmall)) {
                items(items, span = { if (it is PickerItem.Header) GridItemSpan(maxLineSpan) else GridItemSpan(1) },
                    contentType = { it::class }) { item ->
                    when (item) {
                        is PickerItem.Header -> Text(item.title, Modifier.padding(horizontal = UiMetrics.GapSmall,
                            vertical = UiMetrics.GapSmall), style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.Bold, color = colors.textSecondary)
                        is PickerItem.Glyph -> Box(Modifier.size(UiMetrics.Touch)
                            .clickable(role = Role.Button) { onPick(item.value) }.semantics { contentDescription = item.name },
                            contentAlignment = Alignment.Center) {
                            Text(item.value, style = MaterialTheme.typography.titleLarge)
                        }
                    }
                }
            }
        }
    }
}
