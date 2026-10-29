package ai.nuanu.slatrix.ui.mockups

import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp

@Composable
fun SlackHomeScreen(
    channels: List<MockChannel>,
    onChannel: (String) -> Unit,
    onThread: () -> Unit,
    onYou: () -> Unit,
    conversations: List<MockConversation>,
    onDm: (String) -> Unit,
) {
    var query by rememberSaveable { mutableStateOf("") }
    var channelsExpanded by rememberSaveable { mutableStateOf(true) }
    var dmsExpanded by rememberSaveable { mutableStateOf(true) }
    val visibleChannels = channels.filter { it.name.contains(query, ignoreCase = true) }
    val visibleDms = conversations.filter { it.name.contains(query, ignoreCase = true) }
    RootFrame("Studio", onYou, workspace = true) {
        LazyColumn {
            item {
                OutlinedTextField(
                    query, { query = it },
                    Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
                    placeholder = { Text("Search Studio", style = MaterialTheme.typography.bodyLarge) },
                    leadingIcon = { Icon(Icons.Outlined.Search, null) },
                    singleLine = true,
                    shape = MaterialTheme.shapes.large,
                )
                Surface(
                    modifier = Modifier.padding(UiMetrics.GapLarge).width(UiMetrics.ShortcutWidth)
                        .heightIn(min = UiMetrics.ShortcutHeight).clickable(onClick = onThread),
                    shape = MaterialTheme.shapes.large,
                    color = SlatrixTheme.colors.canvas,
                    border = BorderStroke(UiMetrics.Divider, SlatrixTheme.colors.border),
                ) {
                    Column(Modifier.padding(UiMetrics.GapMedium), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                        Icon(Icons.Outlined.Forum, null, Modifier.size(UiMetrics.Icon))
                        Text("Threads", style = MaterialTheme.typography.bodyLarge)
                    }
                }
                HorizontalDivider(color = SlatrixTheme.colors.border)
                RootSection("Channels", Icons.Outlined.Tag, channelsExpanded) { channelsExpanded = !channelsExpanded }
            }
            if (channelsExpanded) {
                items(visibleChannels, key = { "channel:${it.id}" }) { channel ->
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable { onChannel(channel.id) }
                            .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge),
                    ) {
                        Icon(Icons.Outlined.Tag, null, Modifier.size(UiMetrics.CompactAvatar), tint = SlatrixTheme.colors.textSecondary)
                        Text(channel.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
                            fontWeight = if (channel.unread) FontWeight.Bold else FontWeight.Normal)
                        channel.badge?.let { RootBadge(it) }
                    }
                }
            }
            item {
                HorizontalDivider(Modifier.padding(top = UiMetrics.GapSmall), color = SlatrixTheme.colors.border)
                RootSection("Direct messages", Icons.Outlined.Forum, dmsExpanded) { dmsExpanded = !dmsExpanded }
            }
            if (dmsExpanded) {
                items(visibleDms, key = { "dm:${it.id}" }) { conversation ->
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable { onDm(conversation.id) }
                            .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge),
                    ) {
                        RootAvatar(conversation.initials, conversation.colorIndex, UiMetrics.CompactAvatar)
                        Text(conversation.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
                            fontWeight = if (conversation.badge != null) FontWeight.Bold else FontWeight.Normal)
                        conversation.badge?.let { RootBadge(it) }
                    }
                }
            }
            if (visibleChannels.isEmpty() && visibleDms.isEmpty()) item { RootEmpty("No results") }
            item { Spacer(Modifier.height(UiMetrics.GapSection)) }
        }
    }
}

@Composable
fun SlackDmsScreen(conversations: List<MockConversation>, onOpen: (String) -> Unit, onYou: () -> Unit) {
    var unread by rememberSaveable { mutableStateOf(false) }
    val visible = conversations.filter { !unread || it.badge != null }
    RootFrame("Direct messages", onYou) {
        LazyColumn {
            item {
                Row(
                    Modifier.horizontalScroll(rememberScrollState()).padding(UiMetrics.GapLarge),
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium),
                ) {
                    conversations.forEach { conversation ->
                        Column(
                            Modifier.width(UiMetrics.ContactWidth).clickable { onOpen(conversation.id) },
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall),
                        ) {
                            RootAvatar(conversation.initials, conversation.colorIndex, UiMetrics.LargeAvatar)
                            Text(conversation.name.substringBefore(' '), style = MaterialTheme.typography.bodyMedium,
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
                RootFilters(listOf("All", "Unreads"), if (unread) "Unreads" else "All") { unread = it == "Unreads" }
            }
            items(visible, key = { it.id }) { conversation ->
                Row(
                    Modifier.fillMaxWidth().clickable { onOpen(conversation.id) }
                        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapMedium),
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium),
                ) {
                    RootAvatar(conversation.initials, conversation.colorIndex, UiMetrics.Avatar)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
                        Row(horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
                            Text(conversation.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
                                fontWeight = if (conversation.badge != null) FontWeight.Bold else FontWeight.Medium)
                            Text(conversation.time, style = MaterialTheme.typography.bodySmall, color = SlatrixTheme.colors.textSecondary)
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
                            Text(conversation.preview, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
                                color = SlatrixTheme.colors.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            conversation.badge?.let { RootBadge(it) }
                        }
                    }
                }
            }
            if (visible.isEmpty()) item { RootEmpty("No unread messages") }
        }
    }
}

@Composable
fun SlackActivityScreen(items: List<MockActivity>, onThread: () -> Unit, onYou: () -> Unit) {
    var filter by rememberSaveable { mutableStateOf("All") }
    val visible = items.filter {
        when (filter) {
            "Mentions" -> it.action == "mentioned you"
            "Threads" -> it.action == "replied to a thread"
            "DMs" -> it.channel.isEmpty()
            else -> true
        }
    }
    RootFrame("Activity", onYou) {
        Column(Modifier.fillMaxSize()) {
            RootFilters(listOf("All", "DMs", "Mentions", "Threads"), filter) { filter = it }
            LazyColumn(Modifier.fillMaxSize().background(SlatrixTheme.colors.raised)) {
                items(visible, key = { it.id }) { activity ->
                    Row(
                        Modifier.fillMaxWidth().clickable(onClick = onThread).padding(UiMetrics.GapLarge),
                        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall),
                    ) {
                        RootAvatar(activity.initials, activity.colorIndex, UiMetrics.Avatar)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                            Column(verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
                                Row(horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
                                    Text(activity.author, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Bold)
                                    Text(activity.time, style = MaterialTheme.typography.bodySmall, color = SlatrixTheme.colors.textSecondary)
                                }
                                Text("${activity.action} in #${activity.channel}", style = MaterialTheme.typography.bodySmall,
                                    color = SlatrixTheme.colors.textSecondary)
                            }
                            Text(activity.body, style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textBody,
                                maxLines = 3, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    HorizontalDivider(color = SlatrixTheme.colors.border)
                }
                if (visible.isEmpty()) item { RootEmpty("No activity") }
            }
        }
    }
}

@Composable
private fun RootFrame(title: String, onYou: () -> Unit, workspace: Boolean = false, content: @Composable () -> Unit) {
    val colors = SlatrixTheme.colors
    Column(Modifier.fillMaxSize().background(colors.frame)) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = UiMetrics.RootHeaderHeight)
                .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
            horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (workspace) RootAvatar("S", 0, UiMetrics.HeaderAvatar)
            Text(title, Modifier.weight(1f), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
                color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Box(
                Modifier.size(UiMetrics.Touch).clickable(role = Role.Button, onClick = onYou)
                    .semantics { contentDescription = "You" },
                contentAlignment = Alignment.Center,
            ) { RootAvatar(MockData.profile.initials, 0, UiMetrics.HeaderAvatar) }
        }
        Surface(
            Modifier.weight(1f).fillMaxWidth(),
            color = colors.canvas,
            shape = SlatrixTheme.topPanelShape,
            content = content,
        )
    }
}

@Composable
private fun RootSection(label: String, icon: ImageVector, expanded: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(role = Role.Button, onClick = onToggle)
            .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" }
            .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, Modifier.size(UiMetrics.CompactAvatar), tint = SlatrixTheme.colors.textSecondary)
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Bold)
        Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null, Modifier.size(UiMetrics.Icon))
    }
}

@Composable
private fun RootFilters(labels: List<String>, selected: String, onSelect: (String) -> Unit) {
    Row(
        Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall),
    ) {
        labels.forEach { label ->
            Surface(
                modifier = Modifier.heightIn(min = UiMetrics.Touch)
                    .selectable(selected = label == selected, role = Role.Tab, onClick = { onSelect(label) }),
                shape = MaterialTheme.shapes.large,
                color = if (label == selected) SlatrixTheme.colors.textPrimary else SlatrixTheme.colors.canvas,
                contentColor = if (label == selected) SlatrixTheme.colors.canvas else SlatrixTheme.colors.textPrimary,
                border = if (label == selected) null else BorderStroke(UiMetrics.Divider, SlatrixTheme.colors.border),
            ) {
                Box(Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall), contentAlignment = Alignment.Center) {
                    Text(label, style = MaterialTheme.typography.bodyLarge, fontWeight = if (label == selected) FontWeight.Bold else FontWeight.Normal)
                }
            }
        }
    }
}

@Composable
private fun RootAvatar(initials: String, colorIndex: Int, size: Dp) {
    Box(
        Modifier.size(size).clip(MaterialTheme.shapes.small).background(DesignTokens.avatarColors[colorIndex]),
        contentAlignment = Alignment.Center,
    ) {
        Text(initials, style = if (size == UiMetrics.CompactAvatar) MaterialTheme.typography.labelSmall else MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.Bold, color = SlatrixTheme.colors.onAccent)
    }
}

@Composable
private fun RootBadge(text: String) {
    Surface(color = SlatrixTheme.colors.mention, contentColor = SlatrixTheme.colors.onAccent, shape = MaterialTheme.shapes.large) {
        Box(Modifier.heightIn(min = UiMetrics.BadgeMin).padding(horizontal = UiMetrics.GapSmall), contentAlignment = Alignment.Center) {
            Text(text, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
        }
    }
}

@Composable
private fun RootEmpty(label: String) {
    Text(label, Modifier.padding(UiMetrics.GapLarge), style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textSecondary)
}
