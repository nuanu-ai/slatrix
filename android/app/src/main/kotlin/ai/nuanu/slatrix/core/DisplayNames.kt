package ai.nuanu.slatrix.core

import kotlinx.coroutines.CancellationException
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.ProfileDetails
import org.matrix.rustcomponents.sdk.RoomMember

/** How a person is named everywhere, by the rules in `spec/display-names.json`. */
object DisplayNames {
    // The SDK's own tests for a name that could pass for someone else's.
    private val idLike = Regex("@.+[:.].+")
    private val hidden = Regex("[\u2000-\u200D\u0300-\u036F\u2062\u2063\u2800\u061C\uFEFF]")

    /**
     * [userId]'s name: the room's [memberName], else their profile's [globalName], else their ID's localpart. A name the
     * SDK finds [ambiguous], or one that could pass for an ID, carries the ID after it.
     */
    fun name(userId: String, memberName: String?, globalName: String? = null, ambiguous: Boolean = false): String {
        fun usable(name: String?) = name?.trim()?.takeIf { it.isNotEmpty() && it != userId }
        val name = usable(memberName) ?: usable(globalName) ?: return localpart(userId)
        return if (ambiguous || idLike.containsMatchIn(name) || hidden.containsMatchIn(name)) "$name ($userId)" else name
    }

    /** How a mention of someone named [name] reads. */
    fun mention(name: String) = "@$name"

    /** [text] with each user ID in it read as a mention, named from [members] by ID, else by its localpart. */
    fun mentions(text: String, members: Map<String, String>) = ComposerFormat.mentioned.replace(text) {
        if (it.value == "@room") it.value else mention(members[it.value] ?: localpart(it.value))
    }

    /** The user IDs [text] mentions. */
    fun mentioned(text: String) = ComposerFormat.mentioned.findAll(text).map { it.value }.filter { it != "@room" }.toSet()

    /** The part of [userId] between the @ and the server. */
    fun localpart(userId: String) = userId.removePrefix("@").substringBefore(':')
}

/** This member's name in their room. */
fun RoomMember.nameOf() = DisplayNames.name(userId, displayName, ambiguous = isNameAmbiguous)

/** The names [roomId] knows its members [ids] by; anyone it can't find is left out. */
suspend fun Client.memberNames(roomId: String, ids: Set<String>): Map<String, String> {
    if (ids.isEmpty()) return emptyMap()
    val room = try { getRoom(roomId) } catch (_: Exception) { null } ?: return emptyMap()
    return room.use {
        ids.mapNotNull { id ->
            try { id to room.member(id).nameOf() } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null }
        }.toMap()
    }
}

/** [userId]'s name from the SDK's profile of them in a room; the localpart until it's ready. */
fun ProfileDetails.nameOf(userId: String): String {
    val ready = this as? ProfileDetails.Ready
    return DisplayNames.name(userId, ready?.displayName, ambiguous = ready?.displayNameAmbiguous == true)
}
