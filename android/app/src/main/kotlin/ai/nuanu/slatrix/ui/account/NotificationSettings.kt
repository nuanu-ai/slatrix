package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.NotificationPreferences
import ai.nuanu.slatrix.core.NotifyAbout
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Preview
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.matrix.rustcomponents.sdk.NotificationSettings

/** Preferences' Notifications section, reading and saving through [settings] and this phone's preferences. */
@Composable
fun LiveNotificationSettings(settings: suspend () -> NotificationSettings) {
    val preferences = NotificationPreferences(LocalContext.current)
    var notifyAbout by remember { mutableStateOf<NotifyAbout?>(null) }
    var previews by remember { mutableStateOf(preferences.previews) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    suspend fun read() = try { notifyAbout = preferences.notifyAbout(settings()) } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) { }
    LaunchedEffect(Unit) { read() }
    NotificationRows(notifyAbout, previews, error, { choice ->
        val before = notifyAbout
        notifyAbout = choice
        error = null
        scope.launch {
            try { preferences.setNotifyAbout(settings(), choice) } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) {
                notifyAbout = before
                error = "Couldn't save. Try again."
                read()
            }
        }
    }) { previews = it; preferences.previews = it }
}

@Composable
fun NotificationRows(notifyAbout: NotifyAbout?, previews: Boolean, error: String?, onNotifyAbout: (NotifyAbout) -> Unit,
    onPreviews: (Boolean) -> Unit) {
    val colors = SlatrixTheme.colors
    var choosing by rememberSaveable { mutableStateOf(false) }
    if (choosing) {
        AlertDialog(
            onDismissRequest = { choosing = false },
            title = { Text("Notify me about") },
            text = {
                Column(Modifier.selectableGroup()) {
                    NotifyAbout.entries.forEach { choice ->
                        Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch)
                            .selectable(selected = notifyAbout == choice, role = Role.RadioButton,
                                onClick = { choosing = false; onNotifyAbout(choice) }),
                            verticalAlignment = Alignment.CenterVertically) {
                            RadioButton(selected = notifyAbout == choice, onClick = null)
                            Text(choice.label, Modifier.padding(start = UiMetrics.GapSmall), style = MaterialTheme.typography.bodyLarge)
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { choosing = false }) { Text("Cancel") } },
        )
    }
    Column {
        Text("Notifications", Modifier.padding(UiMetrics.GapLarge), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
        PreferenceRow(Icons.Outlined.Notifications, "Notify me about", Modifier.clickable(role = Role.Button) { choosing = true }) {
            // Blank while loading or when rules set elsewhere match no choice, so the row keeps its height.
            Text(error ?: notifyAbout?.label.orEmpty(), style = MaterialTheme.typography.bodyMedium,
                color = if (error != null) colors.destructive else colors.textSecondary)
        }
        PreferenceRow(Icons.Outlined.Preview, "Show message previews",
            Modifier.toggleable(previews, role = Role.Switch, onValueChange = onPreviews), trailing = { Switch(previews, onCheckedChange = null) })
    }
}

@Composable
private fun PreferenceRow(icon: ImageVector, title: String, modifier: Modifier, trailing: @Composable () -> Unit = {},
    subtitle: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.ComposerMinHeight).then(modifier)
        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        Icon(icon, null, Modifier.size(UiMetrics.GapSection))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            subtitle()
        }
        trailing()
    }
}
