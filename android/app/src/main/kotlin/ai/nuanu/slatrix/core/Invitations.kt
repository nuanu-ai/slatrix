package ai.nuanu.slatrix.core

import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.Membership

data class Invitation(
    val id: String,
    val name: String,
    val direct: Boolean = false,
    val space: Boolean = false,
    val inviter: String? = null,
    val initials: String = AvatarPlaceholder.initials(name),
    val colorIndex: Int = AvatarPlaceholder.colorIndex(name),
)

enum class RoomPlacement {
    Conversation, Workspace, Ignored;

    companion object {
        fun of(space: Boolean, membership: Membership) = Ignored
    }
}

object Invitations {
    suspend fun respond(client: Client, roomId: String, accept: Boolean): Boolean = false
}
