package ai.nuanu.slatrix.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.Membership

/** An invitation waiting for you, to a channel, a direct message or a workspace, and who sent it if known. */
data class Invitation(
    val id: String,
    val name: String,
    val direct: Boolean = false,
    val space: Boolean = false,
    val inviter: String? = null,
    val initials: String = AvatarPlaceholder.initials(name),
    val colorIndex: Int = AvatarPlaceholder.colorIndex(name),
)

/** Where a room goes by its membership, as `spec/invitations.json` has it. */
enum class RoomPlacement {
    Conversation, Workspace, Ignored;

    companion object {
        fun of(space: Boolean, membership: Membership) = when (membership) {
            Membership.INVITED -> Conversation
            Membership.JOINED -> if (space) Workspace else Conversation
            else -> Ignored
        }
    }
}

object Invitations {
    /** Joins or declines [roomId] while its invitation is still pending; false when that failed or it no longer is. */
    suspend fun respond(client: Client, roomId: String, accept: Boolean): Boolean = withContext(Dispatchers.Default) {
        try {
            client.getRoom(roomId)?.use { room ->
                if (room.membership() != Membership.INVITED) return@use false
                if (accept) room.join() else room.leave()
                true
            } == true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            false
        }
    }
}
