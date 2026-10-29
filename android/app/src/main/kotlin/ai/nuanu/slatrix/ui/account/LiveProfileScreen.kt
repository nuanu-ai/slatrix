package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Logout
import androidx.compose.material.icons.outlined.Brush
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import kotlinx.coroutines.CancellationException

/**
 * You, pushed from Home's avatar as Slack does: who is signed in, Preferences, and signing out. The profile's name
 * replaces the ID's localpart once [loadName] returns it.
 */
@Composable
fun LiveYouScreen(userId: String, loadName: suspend () -> String?, onPreferences: () -> Unit, onSignOut: () -> Unit,
    onBack: () -> Unit, avatarUrl: String? = null) {
    val colors = SlatrixTheme.colors
    val localpart = userId.removePrefix("@").substringBefore(':')
    val name by produceState<String?>(null, userId) {
        value = try { loadName()?.takeIf { it.isNotBlank() } } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null }
    }
    var confirming by rememberSaveable { mutableStateOf(false) }
    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text("Sign out?") },
            text = { Text(userId) },
            confirmButton = { TextButton(onClick = { confirming = false; onSignOut() }) { Text("Sign out") } },
            dismissButton = { TextButton(onClick = { confirming = false }) { Text("Cancel") } },
        )
    }
    PushedPage("You", onBack) {
        item {
            Row(Modifier.fillMaxWidth().padding(UiMetrics.GapLarge),
                horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                LiveAvatar(AvatarPlaceholder.initials(localpart), AvatarPlaceholder.colorIndex(userId), UiMetrics.ProfileAvatar, avatarUrl)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
                    Text(name ?: localpart, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(userId, style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary)
                }
            }
            HorizontalDivider(Modifier.padding(vertical = UiMetrics.GapSmall), color = colors.border)
            Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(role = Role.Button, onClick = onPreferences)
                .padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Tune, null, Modifier.size(UiMetrics.GapSection))
                Text("Preferences", style = MaterialTheme.typography.bodyLarge)
            }
            Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(role = Role.Button) { confirming = true }
                .padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.AutoMirrored.Outlined.Logout, null, Modifier.size(UiMetrics.GapSection))
                Text("Sign out", style = MaterialTheme.typography.bodyLarge)
            }
        }
    }
}

/** A page pushed over Home: a plain bar with Back and its title, then its rows. */
@Composable
private fun PushedPage(title: String, onBack: () -> Unit, content: LazyListScope.() -> Unit) {
    BackHandler(onBack = onBack)
    Column(Modifier.fillMaxSize().background(SlatrixTheme.colors.canvas).navigationBarsPadding()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = UiMetrics.ComposerMinHeight), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack, modifier = Modifier.size(UiMetrics.Touch)) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back")
            }
            Text(title, Modifier.padding(start = UiMetrics.GapSmall),
                style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        }
        HorizontalDivider(color = SlatrixTheme.colors.border)
        LazyColumn(Modifier.fillMaxSize(), content = content)
    }
}

@Composable
fun LivePreferencesScreen(
    dark: Boolean,
    darkOverride: Boolean?,
    palette: SidebarPalette,
    onColorMode: (Boolean?) -> Unit,
    onPalette: (SidebarPalette) -> Unit,
    onBack: () -> Unit,
) {
    var choosingMode by rememberSaveable { mutableStateOf(false) }
    val colors = SlatrixTheme.colors
    val colorMode = when (darkOverride) { null -> "System default"; false -> "Light"; true -> "Dark" }

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
    PushedPage("Preferences", onBack) {
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
                Text("Color theme", Modifier.padding(UiMetrics.GapLarge), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                Column(Modifier.selectableGroup()) {
                    SidebarPalette.entries.forEach { choice ->
                        Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch)
                            .selectable(selected = palette == choice, role = Role.RadioButton, onClick = { onPalette(choice) })
                            .padding(horizontal = UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(UiMetrics.GapSection).clip(MaterialTheme.shapes.small)
                                .background(DesignTokens.colors(dark, choice).getValue("selectionStrong")))
                            Text(choice.label, Modifier.weight(1f).padding(horizontal = UiMetrics.GapMedium), style = MaterialTheme.typography.bodyLarge)
                            RadioButton(selected = palette == choice, onClick = null)
                        }
                    }
                }
            }
        }
}
