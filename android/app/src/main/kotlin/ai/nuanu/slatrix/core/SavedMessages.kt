package ai.nuanu.slatrix.core

import android.content.Context
import androidx.core.content.edit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.DateDividerMode
import org.matrix.rustcomponents.sdk.EventOrTransactionId
import org.matrix.rustcomponents.sdk.Membership
import org.matrix.rustcomponents.sdk.ProfileDetails
import org.matrix.rustcomponents.sdk.TimelineConfiguration
import org.matrix.rustcomponents.sdk.TimelineFilter
import org.matrix.rustcomponents.sdk.TimelineFocus
import uniffi.matrix_sdk_ui.TimelineEventFocusThreadMode
import uniffi.matrix_sdk_ui.TimelineReadReceiptTracking

/** A message saved for later; [savedAt] is in milliseconds since 1970. */
data class SavedMessage(val roomId: String, val eventId: String, val savedAt: Long)

/** What Later shows of a saved message, read from its conversation as it is now. */
data class SavedPreview(val senderName: String, val body: String, val timestamp: Long)

/** Swift's Date counts seconds from 2001, so the Mac's vault writes savedAt that way. */
private const val SWIFT_EPOCH_MILLIS = 978_307_200_000L
private const val LIMIT = 10_000

/**
 * An account's messages saved for later, newest first, on this device. The Mac keeps them only on its own device too,
 * in its encrypted vault, so the two never share a list; each item is written as the Mac's SavedMessageReference is,
 * and a stored list that breaks the Mac's rules is dropped whole, as the Mac refuses its vault.
 */
class SavedMessageStore(context: Context, private val userId: String) {
    private val values = context.getSharedPreferences("saved-messages", Context.MODE_PRIVATE)

    val saved: List<SavedMessage>
        get() = values.getString(userId, null)?.let(::decode).orEmpty()

    /** Saves the message, or removes it when it is saved, and returns the list it makes. */
    fun toggle(roomId: String, eventId: String, now: Long = System.currentTimeMillis()): List<SavedMessage> {
        val current = saved
        val next = if (current.any { it.roomId == roomId && it.eventId == eventId }) {
            current.filterNot { it.roomId == roomId && it.eventId == eventId }
        } else listOf(SavedMessage(roomId, eventId, now)) + current
        if (!valid(next)) return current
        values.edit { putString(userId, encode(next)) }
        return next
    }

    private fun encode(list: List<SavedMessage>): String = JSONArray(list.map {
        JSONObject().put("roomID", it.roomId).put("eventID", it.eventId).put("savedAt", (it.savedAt - SWIFT_EPOCH_MILLIS) / 1_000.0)
    }).toString()

    private fun decode(stored: String): List<SavedMessage>? = runCatching {
        val array = JSONArray(stored)
        List(array.length()) { index ->
            val item = array.getJSONObject(index)
            val savedAt = item.getDouble("savedAt")
            check(savedAt.isFinite())
            SavedMessage(item.getString("roomID"), item.getString("eventID"), SWIFT_EPOCH_MILLIS + Math.round(savedAt * 1_000))
        }
    }.getOrNull()?.takeIf(::valid)?.sortedByDescending { it.savedAt }

    private fun valid(list: List<SavedMessage>) = list.size <= LIMIT &&
        list.all { isMatrixId(it.roomId, "!") && isMatrixId(it.eventId, "$") } &&
        list.distinctBy { it.roomId to it.eventId }.size == list.size
}

/** Reads saved messages from their conversations. */
class MatrixSaved(private val client: Client) {
    /** The message as its conversation shows it now, or null when you've left it or it can't be read. */
    suspend fun preview(saved: SavedMessage): SavedPreview? = withContext(Dispatchers.Default) {
        try {
            client.getRoom(saved.roomId)?.use { room ->
                if (room.membership() != Membership.JOINED) return@use null
                // Opened at the message alone, as the Mac's preview is, so an edit shows as it reads now.
                room.timelineWithConfiguration(TimelineConfiguration(
                    focus = TimelineFocus.Event(saved.eventId, 0u, TimelineEventFocusThreadMode.Automatic(false)),
                    filter = TimelineFilter.All, internalIdPrefix = null, dateDividerMode = DateDividerMode.DAILY,
                    trackReadReceipts = TimelineReadReceiptTracking.DISABLED, reportUtds = false,
                )).use { timeline ->
                    val event = timeline.getEventTimelineItemByEventId(saved.eventId)
                    if ((event.eventOrTransactionId as? EventOrTransactionId.EventId)?.eventId != saved.eventId) return@use null
                    val body = previewText(event.content) ?: return@use null
                    SavedPreview((event.senderProfile as? ProfileDetails.Ready)?.displayName?.takeIf { it.isNotBlank() } ?: event.sender,
                        body, event.timestamp.coerceAtMost(Long.MAX_VALUE.toULong()).toLong())
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
    }
}
