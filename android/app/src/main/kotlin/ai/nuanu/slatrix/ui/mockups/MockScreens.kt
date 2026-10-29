package ai.nuanu.slatrix.ui.mockups

import ai.nuanu.slatrix.ui.designsystem.AvatarStyle
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.SentimentSatisfied
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight

@Composable
fun YouScreen(dark: Boolean, palette: SidebarPalette, onDarkToggle: () -> Unit, onPalette: (SidebarPalette) -> Unit, onBack: () -> Unit) {
    var preferences by rememberSaveable { mutableStateOf(false) }
    var status by rememberSaveable { mutableStateOf("") }
    var editingStatus by rememberSaveable { mutableStateOf(false) }
    var statusDraft by rememberSaveable { mutableStateOf("") }
    BackHandler(enabled = preferences) { preferences = false }
    if (editingStatus) {
        AlertDialog(
            onDismissRequest = { editingStatus = false },
            title = { Text("Set a status") },
            text = { OutlinedTextField(statusDraft, { statusDraft = it }, label = { Text("What's your status?") }, singleLine = true) },
            confirmButton = { TextButton(onClick = { status = statusDraft; editingStatus = false }) { Text("Save") } },
            dismissButton = { TextButton(onClick = { editingStatus = false }) { Text("Cancel") } },
        )
    }
    Column(Modifier.fillMaxSize().background(SlatrixTheme.colors.canvas)) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = UiMetrics.ComposerMinHeight), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { if (preferences) preferences = false else onBack() }, modifier = Modifier.size(UiMetrics.Touch)) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back")
            }
            Text(if (preferences) "Preferences" else "You", Modifier.padding(start = UiMetrics.GapSmall), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        }
        HorizontalDivider(color = SlatrixTheme.colors.border)
        LazyColumn {
            if (!preferences) {
                item {
                    Row(Modifier.padding(UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.sizeIn(minWidth = UiMetrics.ProfileAvatar, minHeight = UiMetrics.ProfileAvatar).clip(MaterialTheme.shapes.large)
                            .background(DesignTokens.avatarColors[0]).padding(UiMetrics.GapTiny), contentAlignment = Alignment.Center) {
                            Text(MockData.profile.initials, style = AvatarStyle.label, color = SlatrixTheme.colors.onAccent, maxLines = 1, softWrap = false)
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
                            Text(MockData.profile.name, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                            Text("Active", style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textSecondary)
                        }
                    }
                }
                item {
                    Surface(
                        Modifier.fillMaxWidth().padding(UiMetrics.GapLarge).clickable(role = Role.Button) { statusDraft = status; editingStatus = true },
                        shape = MaterialTheme.shapes.extraLarge, color = SlatrixTheme.colors.canvas,
                        border = BorderStroke(UiMetrics.Divider, SlatrixTheme.colors.border),
                    ) {
                        Row(Modifier.heightIn(min = UiMetrics.Touch).padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.SentimentSatisfied, null, Modifier.size(UiMetrics.GapSection))
                            Text(status.ifEmpty { "Update your status" }, style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textSecondary)
                        }
                    }
                }
                item {
                    HorizontalDivider(Modifier.padding(vertical = UiMetrics.GapLarge), color = SlatrixTheme.colors.border)
                    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(role = Role.Button) { preferences = true }.padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.Settings, null, Modifier.size(UiMetrics.GapSection))
                        Text("Preferences", style = MaterialTheme.typography.bodyLarge)
                    }
                }
            } else {
                item {
                    Text("Appearance", Modifier.padding(UiMetrics.GapLarge), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                    Row(Modifier.fillMaxWidth().toggleable(value = dark, role = Role.Switch, onValueChange = { onDarkToggle() }).padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
                        Text("Dark mode", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                        Switch(checked = dark, onCheckedChange = null)
                    }
                    Text("Color theme", Modifier.padding(UiMetrics.GapLarge), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                    listOf(SidebarPalette.Aubergine, SidebarPalette.Lagoon).forEach { choice ->
                        Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).selectable(selected = palette == choice, role = Role.RadioButton, onClick = { onPalette(choice) }).padding(horizontal = UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(UiMetrics.GapSection).clip(MaterialTheme.shapes.small).background(DesignTokens.colors(dark, choice).getValue("selectionStrong")))
                            Text(choice.name, Modifier.weight(1f).padding(horizontal = UiMetrics.GapMedium), style = MaterialTheme.typography.bodyLarge)
                            RadioButton(selected = palette == choice, onClick = null)
                        }
                    }
                }
            }
        }
    }
}
