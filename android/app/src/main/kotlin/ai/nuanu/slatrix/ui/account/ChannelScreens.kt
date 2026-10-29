package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ChannelDirectoryState
import ai.nuanu.slatrix.core.DirectoryChannel
import androidx.compose.runtime.Composable

@Composable
fun BrowseChannelsScreen(title: String, state: ChannelDirectoryState, joined: Set<String>, joining: String?, error: String?,
    onSearch: (String) -> Unit, onMore: () -> Unit, onChannel: (DirectoryChannel) -> Unit, onBack: () -> Unit) {
}

@Composable
fun CreateChannelScreen(workspace: String?, creating: Boolean, error: String?, onCreate: (name: String, topic: String) -> Unit,
    onBack: () -> Unit) {
}
