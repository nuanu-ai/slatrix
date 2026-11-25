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

import ai.nuanu.slatrix.core.AndroidTheme
import ai.nuanu.slatrix.core.AppearancePreferences
import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.DisplayNames
import ai.nuanu.slatrix.ui.designsystem.ThemeSwatchRow
import ai.nuanu.slatrix.ui.designsystem.bubble
import ai.nuanu.slatrix.ui.designsystem.bubbleShape
import ai.nuanu.slatrix.ui.designsystem.message
import ai.nuanu.slatrix.ui.designsystem.wallpaper
import androidx.compose.foundation.border
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.outlined.Contrast
import androidx.compose.material.icons.outlined.Wallpaper
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
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
                OwnAvatar(userId, UiMetrics.ProfileAvatar, avatarUrl)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
                    Text(name ?: localpart, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Black,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    // On one line, cut in the middle so both its name and its server stay readable.
                    Text(userId, style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary, maxLines = 1,
                        overflow = TextOverflow.MiddleEllipsis)
                }
            }
            onViewProfile?.let { view ->
                Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.CompactRow).clickable(role = Role.Button) { view(name) }
                    .padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                    Icon(SlackIcons.Person, null, Modifier.size(UiMetrics.LargeIcon), tint = colors.textSecondary)
                    Text("View profile", style = MaterialTheme.typography.bodyLarge)
                }
            }
            Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.CompactRow).clickable(role = Role.Button, onClick = onPreferences)
                .padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                Icon(SlackIcons.Preferences, null, Modifier.size(UiMetrics.LargeIcon), tint = colors.textSecondary)
                Text("Preferences", style = MaterialTheme.typography.bodyLarge)
            }
            Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.CompactRow).clickable(role = Role.Button) { confirming = true }
                .padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge), verticalAlignment = Alignment.CenterVertically) {
                Icon(SlackIcons.SignOut, null, Modifier.size(UiMetrics.LargeIcon), tint = colors.textSecondary)
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
    theme: AndroidTheme,
    onColorMode: (Boolean?) -> Unit,
    onTheme: (AndroidTheme) -> Unit,
    onBack: () -> Unit,
    chatWallpaper: Boolean = true,
    onChatWallpaper: (Boolean) -> Unit = {},
    increaseContrast: Boolean = false,
    onIncreaseContrast: (Boolean) -> Unit = {},
    activeWorkspaceId: String? = null,
    activeWorkspaceName: String? = null,
    workspaceTheme: AndroidTheme? = null,
    onWorkspaceTheme: (String, AndroidTheme?) -> Unit = { _, _ -> },
    messageScale: Float = 1f,
    onMessageScale: (Float) -> Unit = {},
    notifications: @Composable () -> Unit = {},
) {
    var choosingMode by rememberSaveable { mutableStateOf(false) }
    val hasWorkspace = activeWorkspaceId != null && activeWorkspaceName != null
    // Null until the user taps a scope option, so late-arriving workspace names still open on an existing override.
    var explicitScopeWorkspace by rememberSaveable(activeWorkspaceId) { mutableStateOf<Boolean?>(null) }
    val scopeWorkspace = hasWorkspace && (explicitScopeWorkspace ?: (workspaceTheme != null))
    val shownTheme = if (scopeWorkspace) (workspaceTheme ?: theme) else theme
    val onPickTheme: (AndroidTheme) -> Unit = { choice ->
        if (scopeWorkspace) onWorkspaceTheme(activeWorkspaceId, choice)
        else onTheme(choice)
    }
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
            if (hasWorkspace) {
                WorkspaceThemeScope(
                    workspaceName = activeWorkspaceName,
                    editingWorkspace = scopeWorkspace,
                    workspaceTheme = workspaceTheme,
                    onEditingWorkspace = { explicitScopeWorkspace = it },
                    onReset = { onWorkspaceTheme(activeWorkspaceId, null) },
                )
            }
            ThemePaletteGrid(
                selected = shownTheme,
                dark = dark,
                increaseContrast = increaseContrast,
                onSelect = onPickTheme,
            )
            PreferenceRow(
                Icons.Outlined.Wallpaper,
                "Chat wallpaper",
                Modifier.toggleable(chatWallpaper, role = Role.Switch, onValueChange = onChatWallpaper),
                trailing = { Switch(chatWallpaper, onCheckedChange = null) },
            )
            PreferenceRow(
                Icons.Outlined.Contrast,
                "Increase contrast",
                Modifier.toggleable(increaseContrast, role = Role.Switch, onValueChange = onIncreaseContrast),
                trailing = { Switch(increaseContrast, onCheckedChange = null) },
            )
            PreferenceHeading("Message text size")
            MessageTextSize(messageScale, onMessageScale)
            About()
        }
    }
}

@Composable
private fun WorkspaceThemeScope(
    workspaceName: String,
    editingWorkspace: Boolean,
    workspaceTheme: AndroidTheme?,
    onEditingWorkspace: (Boolean) -> Unit,
    onReset: () -> Unit,
) {
    val colors = SlatrixTheme.colors
    val segmentShape = MaterialTheme.shapes.small
    val density = LocalDensity.current
    val options = listOf("All workspaces" to false, workspaceName to true)
    Column(Modifier.padding(start = PreferenceInset, end = UiMetrics.GapLarge, top = UiMetrics.GapSmall)) {
        BoxWithConstraints(
            Modifier
                .fillMaxWidth()
                .clip(MaterialTheme.shapes.medium)
                .background(colors.raised)
                .padding(UiMetrics.GapTiny)
                .selectableGroup(),
        ) {
            // Keep both segments on one compact row on standard phones; stack only at large font scales or narrow widths (< 340dp).
            val sideBySide = density.fontScale < ScopeStackFontScale && maxWidth >= UiMetrics.NarrowPhone - PreferenceInset - UiMetrics.GapTiny
            @Composable
            fun Segment(label: String, forWorkspace: Boolean, modifier: Modifier) {
                val selected = editingWorkspace == forWorkspace
                Box(
                    modifier
                        .heightIn(min = UiMetrics.SectionHeader)
                        .clip(segmentShape)
                        .then(
                            if (selected) Modifier.background(colors.canvas).border(UiMetrics.Divider, colors.borderStrong, segmentShape)
                            else Modifier,
                        )
                        .selectable(selected = selected, role = Role.Tab) { onEditingWorkspace(forWorkspace) }
                        .padding(horizontal = UiMetrics.GapSmall, vertical = UiMetrics.GapSmall),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        label,
                        Modifier.fillMaxWidth(),
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                        color = if (selected) colors.textPrimary else colors.textSecondary,
                        textAlign = TextAlign.Center,
                        maxLines = if (sideBySide) 1 else 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (sideBySide) {
                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
                    options.forEach { (label, forWorkspace) -> Segment(label, forWorkspace, Modifier.weight(1f).fillMaxHeight()) }
                }
            } else {
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
                    options.forEach { (label, forWorkspace) -> Segment(label, forWorkspace, Modifier.fillMaxWidth()) }
                }
            }
        }
        if (workspaceTheme != null) {
            Row(
                Modifier.fillMaxWidth().padding(top = UiMetrics.GapTiny),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                val note = if (editingWorkspace) "Custom theme for $workspaceName" else "$workspaceName uses ${workspaceTheme.label}"
                Text(note, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = colors.textSecondary,
                    maxLines = 2, overflow = TextOverflow.Ellipsis)
                TextButton(onClick = onReset, contentPadding = PaddingValues(horizontal = UiMetrics.GapSmall)) {
                    Text("Use default")
                }
            }
        }
    }
}

private const val ScopeStackFontScale = 1.5f

@Composable
private fun ThemePaletteGrid(
    selected: AndroidTheme,
    dark: Boolean,
    increaseContrast: Boolean,
    onSelect: (AndroidTheme) -> Unit,
) {
    val colors = SlatrixTheme.colors
    val neutral = remember { AndroidTheme.entries.filter { !it.colored } }
    val colored = remember { AndroidTheme.entries.filter { it.colored } }
    Column(
        Modifier
            .fillMaxWidth()
            .padding(start = PreferenceInset, end = UiMetrics.GapLarge, top = UiMetrics.GapSmall, bottom = UiMetrics.GapSmall)
            .selectableGroup(),
        verticalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall),
    ) {
        Text("Neutral", style = MaterialTheme.typography.labelLarge, color = colors.textSecondary)
        ThemeSwatchRow(neutral, selected, dark, increaseContrast, onSelect)
        Text("Colored", Modifier.padding(top = UiMetrics.GapTiny), style = MaterialTheme.typography.labelLarge, color = colors.textSecondary)
        ThemeSwatchRow(colored, selected, dark, increaseContrast, onSelect)
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
    // Set over a chat-wallpaper preview card so the borderless light-mode bubble reads clearly against the canvas.
    Box(Modifier.padding(start = PreferenceInset, end = UiMetrics.GapLarge).fillMaxWidth()
        .clip(MaterialTheme.shapes.large).wallpaper().padding(UiMetrics.GapMedium)) {
        Text(MessagePreview, Modifier.padding(end = UiMetrics.IncomingGutterNarrow)
            .wrapContentWidth(Alignment.Start).bubble(shape, colors.bubbleIn, colors.bubbleEdge)
            .padding(horizontal = UiMetrics.BubbleInset, vertical = UiMetrics.BubbleInsetVertical),
            style = MaterialTheme.typography.message, color = colors.textBody)
    }
    Row(Modifier.fillMaxWidth().padding(start = PreferenceInset, end = UiMetrics.GapLarge, top = UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        Text("A", style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
        Slider(scales.indexOf(scale).coerceAtLeast(0).toFloat(), { onScale(scales[it.roundToInt()]) },
            Modifier.weight(1f).semantics { contentDescription = "Message text size" },
            valueRange = 0f..scales.lastIndex.toFloat(), steps = scales.size - 2)
        Text("A", style = MaterialTheme.typography.titleLarge, color = colors.textSecondary)
    }
}
