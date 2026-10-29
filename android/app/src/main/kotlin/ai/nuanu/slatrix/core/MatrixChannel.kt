package ai.nuanu.slatrix.core

import org.matrix.rustcomponents.sdk.Client

data class ChannelMember(val id: String, val name: String) {
    val initials get() = AvatarPlaceholder.initials(name)
    val colorIndex get() = AvatarPlaceholder.colorIndex(name)
}

enum class NotificationChoice { Default, All, Mentions, Nothing }

data class NotificationSetting(val choice: NotificationChoice, val default: NotificationChoice)

class ChannelActionFailure(message: String) : Exception(message)

class MatrixChannel(private val client: Client, private val roomId: String) {
    suspend fun members(): List<ChannelMember> = emptyList()
    suspend fun save(name: String, topic: String) = Unit
    suspend fun leave() = Unit
    suspend fun invite(userId: String) = Unit
    suspend fun notifications(): NotificationSetting = NotificationSetting(NotificationChoice.Default, NotificationChoice.All)
    suspend fun setNotifications(choice: NotificationChoice) = Unit
}
