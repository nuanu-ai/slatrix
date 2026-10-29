package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ChannelMember
import ai.nuanu.slatrix.core.NotificationChoice
import ai.nuanu.slatrix.core.NotificationSetting
import ai.nuanu.slatrix.core.RoomSummary
import androidx.compose.runtime.Composable

data class ChannelDetailsActions(
    val members: suspend () -> List<ChannelMember> = { emptyList() },
    val save: suspend (name: String, topic: String) -> Unit = { _, _ -> },
    val leave: suspend () -> Unit = {},
    val invite: suspend (userId: String) -> Unit = {},
    val notifications: suspend () -> NotificationSetting = { NotificationSetting(NotificationChoice.Default, NotificationChoice.All) },
    val setNotifications: suspend (NotificationChoice) -> Unit = {},
)

@Composable
fun ChannelDetailsScreen(room: RoomSummary, me: String?, actions: ChannelDetailsActions, onLeft: () -> Unit, onBack: () -> Unit) = Unit
