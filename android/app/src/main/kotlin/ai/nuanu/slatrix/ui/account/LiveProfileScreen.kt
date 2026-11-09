package ai.nuanu.slatrix.ui.account

import androidx.compose.foundation.layout.PaddingValues
import ai.nuanu.slatrix.R
import ai.nuanu.slatrix.ui.designsystem.ListHeading
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.TextButton
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import ai.nuanu.slatrix.BuildConfig
import androidx.compose.ui.platform.LocalUriHandler

import ai.nuanu.slatrix.core.AppearancePreferences
import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.DisplayNames
import ai.nuanu.slatrix.ui.designsystem.bubble
import ai.nuanu.slatrix.ui.designsystem.bubbleShape
import ai.nuanu.slatrix.ui.designsystem.message
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import kotlin.math.roundToInt
import ai.nuanu.slatrix.ui.designsystem.Motion
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.graphicsLayer
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import ai.nuanu.slatrix.ui.designsystem.rememberPredictiveBack
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Brush
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow

/**
 * You, pushed from Home's avatar as Slack does: who is signed in, Preferences, and signing out. Without a profile
 * [name], the ID's localpart stands in.
 */
@Composable
fun LiveYouScreen(userId: String, name: String?, onPreferences: () -> Unit, onSignOut: () -> Unit,
    onViewProfile: ((name: String?) -> Unit)? = null, onBack: () -> Unit, avatarUrl: String? = null) {
    val colors = SlatrixTheme.colors
    val localpart = DisplayNames.localpart(userId)
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
                    Text(name ?: localpart, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Black,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    // On one line, cut in the middle so both its name and its server stay readable.
                    Text(userId, style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary, maxLines = 1,
                        overflow = TextOverflow.MiddleEllipsis)
                }
            }
            Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).padding(horizontal = UiMetrics.GapLarge),
                horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
                val connection = LocalConnection.current
                Column(Modifier.weight(1f)) {
                    Text("Connection", style = MaterialTheme.typography.bodyLarge)
                    Text(connection.label, style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary)
                }
                LocalConnectionRetry.current?.let { retry ->
                    IconButton(onClick = retry, modifier = Modifier.size(UiMetrics.Touch)) {
                        Icon(SlackIcons.Reconnect, "Reconnect", Modifier.size(UiMetrics.Icon))
                    }
                }
            }
            onViewProfile?.let { view ->
                Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.CompactRow).clickable(role = Role.Button) { view(name) }
                    .padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                    Icon(SlackIcons.Person, null, Modifier.size(UiMetrics.Icon))
                    Text("View profile", style = MaterialTheme.typography.bodyLarge)
                }
            }
            Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.CompactRow).clickable(role = Role.Button, onClick = onPreferences)
                .padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                Icon(SlackIcons.Preferences, null, Modifier.size(UiMetrics.Icon))
                Text("Preferences", style = MaterialTheme.typography.bodyLarge)
            }
            Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.CompactRow).clickable(role = Role.Button) { confirming = true }
                .padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                Icon(SlackIcons.SignOut, null, Modifier.size(UiMetrics.Icon))
                Text("Sign out", style = MaterialTheme.typography.bodyLarge)
            }
        }
    }
}

/** True where a page shows again because the one over it went back, which is instant. */
/**
 * A pushed page: a plain bar with Back, its title and maybe an action such as Save, then its rows. The workspace slides
 * it in, as Slack's pages come in from the side.
 */
@Composable
internal fun PushedPage(title: String, onBack: () -> Unit, action: @Composable () -> Unit = {}, content: LazyListScope.() -> Unit) {
    val back = rememberPredictiveBack(onBack = onBack)
    Column(Modifier.fillMaxSize().graphicsLayer {
        // A back swipe carries the page off under the finger, over the one it goes back to.
        translationX = back.value * size.width
    }.background(SlatrixTheme.colors.canvas).navigationBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = UiMetrics.HeaderRow).padding(horizontal = UiMetrics.GapTiny),
            verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack, modifier = Modifier.size(UiMetrics.Touch)) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back")
            }
            Text(title, Modifier.weight(1f).padding(start = UiMetrics.GapSmall),
                style = MaterialTheme.typography.titleLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            action()
        }
        LazyColumn(Modifier.fillMaxSize(), content = content)
    }
}

@Composable
fun LivePreferencesScreen(
    dark: Boolean,
    darkOverride: Boolean?,
    wallpaperColors: Boolean,
    onColorMode: (Boolean?) -> Unit,
    onWallpaperColors: (Boolean) -> Unit,
    onBack: () -> Unit,
    messageScale: Float = 1f,
    onMessageScale: (Float) -> Unit = {},
    notifications: @Composable () -> Unit = {},
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
                notifications()
                PreferenceHeading("Appearance")
                PreferenceRow(Icons.Outlined.Brush, "Color mode", Modifier.clickable(role = Role.Button) { choosingMode = true }) {
                    Text(colorMode, style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary)
                }
                PreferenceHeading("Message text size")
                MessageTextSize(messageScale, onMessageScale)
                PreferenceHeading("Colors")
                Column(Modifier.selectableGroup()) {
                    listOf("Slatrix" to false, "From your wallpaper" to true).forEach { (label, choice) ->
                        Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch)
                            .selectable(selected = wallpaperColors == choice, role = Role.RadioButton, onClick = { onWallpaperColors(choice) })
                            .padding(start = PreferenceInset, end = UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                            Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                            RadioButton(selected = wallpaperColors == choice, onClick = null)
                        }
                    }
                }
                About()
            }
        }
}

/** About, a card set apart from the settings above it, as on the Mac: the app's icon beside its name, version and links. */
@Composable
private fun About() {
    val colors = SlatrixTheme.colors
    val uris = LocalUriHandler.current
    val icon = UiMetrics.ProfileAvatar
    // No side padding, so the links line up with the name above them and fit a narrow phone; they keep their touch height.
    val flush = PaddingValues()
    Row(Modifier.padding(UiMetrics.GapLarge).fillMaxWidth().background(colors.raised, MaterialTheme.shapes.large).padding(UiMetrics.GapLarge),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        // The launcher's two layers, cut to the 72 of their 108 dp a launcher shows.
        Box(Modifier.size(icon).clip(CircleShape), contentAlignment = Alignment.Center) {
            listOf(R.drawable.ic_launcher_background, R.drawable.ic_launcher_foreground).forEach {
                Image(painterResource(it), null, Modifier.requiredSize(icon * 108 / 72))
            }
        }
        Column(Modifier.weight(1f)) {
            ListHeading("Slatrix")
            Text("Version ${BuildConfig.VERSION_NAME}", style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary)
            TextButton({ uris.openUri("https://nuanu.ai") }, contentPadding = flush) { Text("© 2026 Nuanu AI Lab") }
            TextButton({ uris.openUri("https://github.com/nuanu-ai/slatrix") }, contentPadding = flush) { Text("Source code on GitHub") }
        }
    }
}

/** What the message text size preview says. */
internal const val MessagePreview = "Morning! The new onboarding copy is in the doc, take a look when you can."

/** A message set at the chosen size over a slider of the sizes, as a messenger's text size setting shows it. */
@Composable
private fun MessageTextSize(scale: Float, onScale: (Float) -> Unit) {
    val colors = SlatrixTheme.colors
    val scales = AppearancePreferences.MessageScales
    val shape = remember { bubbleShape(own = false, grouped = false, last = true) }
    // Laid out as an incoming message is, keeping its gutter on the far side.
    Text(MessagePreview, Modifier.padding(start = PreferenceInset, end = UiMetrics.GapLarge + UiMetrics.IncomingGutterNarrow)
        .wrapContentWidth(Alignment.Start).bubble(shape, colors.bubbleIn, colors.bubbleEdge).padding(horizontal = UiMetrics.GapMedium, vertical = UiMetrics.GapSmall),
        style = MaterialTheme.typography.message, color = colors.textBody)
    Row(Modifier.fillMaxWidth().padding(start = PreferenceInset, end = UiMetrics.GapLarge, top = UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        Text("A", style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
        Slider(scales.indexOf(scale).coerceAtLeast(0).toFloat(), { onScale(scales[it.roundToInt()]) },
            Modifier.weight(1f).semantics { contentDescription = "Message text size" },
            valueRange = 0f..scales.lastIndex.toFloat(), steps = scales.size - 2)
        Text("A", style = MaterialTheme.typography.titleLarge, color = colors.textSecondary)
    }
}
