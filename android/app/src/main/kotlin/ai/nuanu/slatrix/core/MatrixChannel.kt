package ai.nuanu.slatrix.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.Membership
import org.matrix.rustcomponents.sdk.MembershipState
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.RoomNotificationMode
import uniffi.matrix_sdk_base.EncryptionState
import uniffi.ruma_events.StateEventType

data class ChannelMember(val id: String, val name: String) {
    val initials get() = AvatarPlaceholder.initials(name)
    val colorIndex get() = AvatarPlaceholder.colorIndex(name)
}

/** When a conversation notifies you, as on the Mac: the account's default for its kind, or a choice of its own. */
enum class NotificationChoice { Default, All, Mentions, Nothing }

/** The room's [choice] and what [NotificationChoice.Default] means for it. */
data class NotificationSetting(val choice: NotificationChoice, val default: NotificationChoice)

/** A failed action's message, said to the person as is. */
class ChannelActionFailure(message: String) : Exception(message)

/**
 * What a conversation's details change. Each action reads the room again and checks you're still in it and may do it,
 * as the Mac's services do, since the summary on screen may be a sync behind.
 */
class MatrixChannel(private val client: Client, private val roomId: String) {
    /** Who's in the conversation, by name. */
    suspend fun members(): List<ChannelMember> = joined { room ->
        val members = mutableListOf<ChannelMember>()
        room.members().use { iterator ->
            while (true) {
                val chunk = iterator.nextChunk(500u) ?: break
                chunk.filter { it.membership is MembershipState.Join }.mapTo(members) { member ->
                    ChannelMember(member.userId, member.displayName?.takeIf { it.isNotBlank() }
                        ?: member.userId.removePrefix("@").substringBefore(':'))
                }
            }
        }
        members.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER, ChannelMember::name).thenBy { it.id })
    }

    /** Saves the name and description that changed; a description saved before the name failed still counts. */
    suspend fun save(name: String?, topic: String?) = joined("Join this conversation before editing its details.") { room ->
        val info = room.roomInfo()
        val renaming = name != null && name != info.rawName.orEmpty()
        val retopic = topic != null && topic != info.topic.orEmpty()
        if (renaming && name!!.isBlank()) throw ChannelActionFailure("Enter a name.")
        room.getPowerLevels().use { powers ->
            if (renaming && !powers.canOwnUserSendState(StateEventType.RoomName) ||
                retopic && !powers.canOwnUserSendState(StateEventType.RoomTopic)) {
                throw ChannelActionFailure("You don’t have permission to change this conversation’s details.")
            }
        }
        if (renaming) room.setName(name!!)
        try {
            if (retopic) room.setTopic(topic!!)
        } catch (failure: Exception) {
            if (failure is CancellationException || !renaming) throw failure
            throw ChannelActionFailure("The name was saved. The description couldn’t be saved.")
        }
    }

    suspend fun leave() = joined { room -> room.leave() }

    suspend fun invite(userId: String) = joined("Join this conversation before inviting people.") { room ->
        val id = userId.trim()
        if (!ComposerFormat.userID.matches(id)) throw ChannelActionFailure("Enter a complete Matrix ID, such as @name:example.org.")
        room.getPowerLevels().use { powers ->
            if (!powers.canOwnUserInvite()) throw ChannelActionFailure("You don’t have permission to invite people here.")
        }
        room.inviteUserById(id)
    }

    suspend fun notifications(): NotificationSetting = joined { room ->
        client.getNotificationSettings().use { settings ->
            val encrypted = when (room.latestEncryptionState()) {
                EncryptionState.ENCRYPTED -> true
                EncryptionState.NOT_ENCRYPTED -> false
                // Its rules depend on whether it's encrypted, so the choice waits until that's known.
                EncryptionState.UNKNOWN -> throw ChannelActionFailure("This conversation is still loading. Try again.")
            }
            val oneToOne = room.activeMembersCount() == 2uL
            val current = settings.getRoomNotificationSettings(roomId, encrypted, oneToOne)
            NotificationSetting(if (current.isDefault) NotificationChoice.Default else choice(current.mode),
                choice(settings.getDefaultRoomNotificationMode(encrypted, oneToOne)))
        }
    }

    suspend fun setNotifications(choice: NotificationChoice) = joined { _ ->
        client.getNotificationSettings().use { settings ->
            when (choice) {
                NotificationChoice.Default -> settings.restoreDefaultRoomNotificationMode(roomId)
                NotificationChoice.All -> settings.setRoomNotificationMode(roomId, RoomNotificationMode.ALL_MESSAGES)
                NotificationChoice.Mentions -> settings.setRoomNotificationMode(roomId, RoomNotificationMode.MENTIONS_AND_KEYWORDS_ONLY)
                NotificationChoice.Nothing -> settings.setRoomNotificationMode(roomId, RoomNotificationMode.MUTE)
            }
        }
    }

    private fun choice(mode: RoomNotificationMode) = when (mode) {
        RoomNotificationMode.ALL_MESSAGES -> NotificationChoice.All
        RoomNotificationMode.MENTIONS_AND_KEYWORDS_ONLY -> NotificationChoice.Mentions
        RoomNotificationMode.MUTE -> NotificationChoice.Nothing
    }

    /** Runs [action] on the room while you're in it, off the main thread; the server's failures read as one message. */
    private suspend fun <T> joined(notJoined: String = "You’re no longer in this conversation.", action: suspend (Room) -> T): T =
        withContext(Dispatchers.Default) {
            try {
                (client.getRoom(roomId) ?: throw ChannelActionFailure(notJoined)).use { room ->
                    if (room.membership() != Membership.JOINED) throw ChannelActionFailure(notJoined)
                    action(room)
                }
            } catch (failure: Exception) {
                if (failure is CancellationException || failure is ChannelActionFailure) throw failure
                throw ChannelActionFailure("Something went wrong. Try again.")
            }
        }
}
