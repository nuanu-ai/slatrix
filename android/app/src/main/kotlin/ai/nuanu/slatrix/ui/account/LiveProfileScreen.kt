package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.ui.designsystem.AvatarStyle
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Brush
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.*
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
import androidx.compose.ui.text.style.TextOverflow

@Composable
fun LiveProfileScreen(
    userId: String,
    dark: Boolean,
    darkOverride: Boolean?,
    palette: SidebarPalette,
    onColorMode: (Boolean?) -> Unit,
    onPalette: (SidebarPalette) -> Unit,
    onBack: () -> Unit,
) {
    var preferences by rememberSaveable { mutableStateOf(false) }
    var choosingMode by rememberSaveable { mutableStateOf(false) }
    val colors = SlatrixTheme.colors
    val localpart = userId.removePrefix("@").substringBefore(':')
    val colorMode = when (darkOverride) { null -> "System default"; false -> "Light"; true -> "Dark" }
    BackHandler { if (preferences) preferences = false else onBack() }

    if (choosingMode) {
        AlertDialog(
            onDismissRequest = { choosingMode = false },
            title = { Text("Color mode") },
            text = {
                Column(Modifier.selectableGroup()) {
                    listOf("System default" to null, "Light" to false, "Dark" to true).forEach { (label, value) ->
                        Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch)
                            .selectable(selected = darkOverride == value, role = Role.RadioButton,
                                onClick = { onColorMode(value); choosingMode = false }),
                            verticalAlignment = Alignment.CenterVertically) {
                            RadioButton(selected = darkOverride == value, onClick = null)
                            Text(label, Modifier.padding(start = UiMetrics.GapSmall), style = MaterialTheme.typography.bodyLarge)
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { choosingMode = false }) { Text("Cancel") } },
        )
    }
    Column(Modifier.fillMaxSize().background(colors.canvas).navigationBarsPadding()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = UiMetrics.ComposerMinHeight), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { if (preferences) preferences = false else onBack() }, modifier = Modifier.size(UiMetrics.Touch)) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back")
            }
            Text(if (preferences) "Preferences" else "You", Modifier.padding(start = UiMetrics.GapSmall),
                style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        }
        HorizontalDivider(color = colors.border)
        LazyColumn {
            if (!preferences) {
                item {
                    Row(Modifier.fillMaxWidth().padding(UiMetrics.GapLarge),
                        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(UiMetrics.ProfileAvatar).clip(MaterialTheme.shapes.large)
                            .background(DesignTokens.avatarColors[AvatarPlaceholder.colorIndex(userId)]), contentAlignment = Alignment.Center) {
                            Text(AvatarPlaceholder.initials(localpart), style = AvatarStyle.label, color = colors.onAccent, maxLines = 1)
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
                            Text(localpart, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold,
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(userId, style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary)
                        }
                    }
                    HorizontalDivider(Modifier.padding(vertical = UiMetrics.GapLarge), color = colors.border)
                    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(role = Role.Button) { preferences = true }
                        .padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.Settings, null, Modifier.size(UiMetrics.GapSection))
                        Text("Preferences", style = MaterialTheme.typography.bodyLarge)
                    }
                }
            } else {
                item {
                    Text("Appearance", Modifier.padding(UiMetrics.GapLarge), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.ComposerMinHeight).clickable(role = Role.Button) { choosingMode = true }
                        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
                        Icon(Icons.Outlined.Brush, null, Modifier.size(UiMetrics.GapSection))
                        Column {
                            Text("Color mode", style = MaterialTheme.typography.bodyLarge)
                            Text(colorMode, style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary)
                        }
                    }
                }
            }
        }
    }
}
