package ai.nuanu.slatrix.core

import android.content.Context
import androidx.core.content.edit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.DateDividerMode
import org.matrix.rustcomponents.sdk.EventOrTransactionId
import org.matrix.rustcomponents.sdk.Membership
import org.matrix.rustcomponents.sdk.ProfileDetails
import org.matrix.rustcomponents.sdk.RawAccountDataListener
import org.matrix.rustcomponents.sdk.TimelineConfiguration
import org.matrix.rustcomponents.sdk.TimelineFilter
import org.matrix.rustcomponents.sdk.TimelineFocus
import uniffi.matrix_sdk_ui.TimelineEventFocusThreadMode
import uniffi.matrix_sdk_ui.TimelineReadReceiptTracking

/** Where a message stands in Later: Slack's In progress, Archived and Completed tabs. */
enum class LaterState(val key: String, val title: String) {
    IN_PROGRESS("in_progress", "In progress"), ARCHIVED("archived", "Archived"), COMPLETED("completed", "Completed")
}

/**
 * A message saved for later; [savedAt], when it was saved, removed or last changed, and [remindAt], when its reminder
 * is due, are in milliseconds since 1970. Only a message in progress has a reminder.
 */
data class SavedMessage(val roomId: String, val eventId: String, val savedAt: Long,
    val state: LaterState = LaterState.IN_PROGRESS, val remindAt: Long? = null) {
    fun overdue(now: Long) = remindAt != null && remindAt <= now
}

/** Remind me's choices, as Slack offers them. */
enum class ReminderPreset(val title: String) {
    IN_20_MINUTES("In 20 minutes"), IN_1_HOUR("In 1 hour"), IN_3_HOURS("In 3 hours"), TOMORROW("Tomorrow"), NEXT_WEEK("Next week");

    /** Real minutes and hours from [now]; tomorrow and next week at 9:00 on [zone]'s clock. */
    fun at(now: Long, zone: ZoneId = ZoneId.systemDefault()): Long {
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        val nine = { day: LocalDate -> day.atTime(9, 0).atZone(zone).toInstant().toEpochMilli() }
        return when (this) {
            IN_20_MINUTES -> now + 20 * 60_000L
            IN_1_HOUR -> now + 60 * 60_000L
            IN_3_HOURS -> now + 3 * 60 * 60_000L
            TOMORROW -> nine(today.plusDays(1))
            NEXT_WEEK -> nine(today.with(TemporalAdjusters.next(DayOfWeek.MONDAY)))
        }
    }
}

/** What Later shows of a saved message, read from its conversation as it is now. */
data class SavedPreview(val senderId: String, val senderName: String, val body: String, val timestamp: Long, val avatarUrl: String? = null)

/** The global account data event that holds an account's Later, as the Mac names it. */
const val SAVED_MESSAGES_TYPE = "ai.nuanu.slatrix.later"
private const val SAVED_LIMIT = 10_000
private const val REMOVED_LIMIT = 1_000
/** The largest integer JSON numbers hold exactly. */
private const val MAX_TIMESTAMP = 9_007_199_254_740_991L

/**
 * Later, one list per account that every device shares through account data, by the rules in
 * `spec/saved-messages.json`, as the Mac keeps it. A message keeps only its latest entry, saved or removed, so merging
 * two devices' lists never loses a save and never brings back a removal. Only IDs and times, since the homeserver
 * reads account data.
 */
data class SavedList(val saved: List<SavedMessage> = emptyList(), val removed: List<SavedMessage> = emptyList()) {
    /** What this device and the account know between them. */
    fun merged(other: SavedList) = normalized(saved + other.saved, removed + other.removed)

    /**
     * Saves or removes the message, stamped after any entry it has so a slow clock can't lose the change; a message
     * already as asked stays as it is.
     */
    fun setting(roomId: String, eventId: String, saved: Boolean, now: Long): SavedList {
        if ((find(roomId, eventId) != null) == saved) return this
        return stamped(SavedMessage(roomId, eventId, now), saved)
    }

    /** Moves a saved message to another tab, clearing its reminder; one already there stays as it is. */
    fun changing(roomId: String, eventId: String, state: LaterState, now: Long): SavedList {
        val current = find(roomId, eventId) ?: return this
        if (current.state == state) return this
        return stamped(SavedMessage(roomId, eventId, now, state), true)
    }

    /** Sets the message's reminder, or clears it with null, keeping it in progress and saving it if it wasn't. */
    fun reminding(roomId: String, eventId: String, remindAt: Long?, now: Long): SavedList {
        val current = find(roomId, eventId)
        if (remindAt == null && current?.remindAt == null) return this
        if (current != null && current.state == LaterState.IN_PROGRESS && current.remindAt == remindAt) return this
        return stamped(SavedMessage(roomId, eventId, now, remindAt = remindAt), true)
    }

    /** A tab's messages: In progress puts reminders first, soonest due first; every tab is otherwise newest first. */
    fun tab(state: LaterState): List<SavedMessage> {
        val shown = saved.filter { it.state == state }
        if (state != LaterState.IN_PROGRESS) return shown
        return shown.filter { it.remindAt != null }.sortedBy { it.remindAt } + shown.filter { it.remindAt == null }
    }

    /** The reminders still to come, soonest first: what a device notifies of. */
    fun reminders(now: Long) = tab(LaterState.IN_PROGRESS).filter { (it.remindAt ?: 0) > now }

    private fun find(roomId: String, eventId: String) = saved.firstOrNull { it.roomId == roomId && it.eventId == eventId }

    /** The new entry lands after any the message has, so a slow clock can't lose the change. */
    private fun stamped(change: SavedMessage, saved: Boolean): SavedList {
        val previous = (this.saved + removed).filter { it.roomId == change.roomId && it.eventId == change.eventId }.maxOfOrNull { it.savedAt }
        val entry = change.copy(savedAt = maxOf(change.savedAt, previous?.plus(1) ?: 0))
        return if (saved) normalized(this.saved + entry, removed) else normalized(this.saved, removed + entry)
    }

    /** The content to write over the account's list, or null when it already says the same. */
    fun content(over: SavedList): String? = if (this == over) null else json()

    /** Both lists, newest first, as the account data event holds them. */
    fun json(): String = JSONObject().put("saved", entries(saved)).put("removed", entries(removed)).toString()

    companion object {
        /** The content of the account data event; null, or anything that breaks the rules, reads as nothing saved. */
        fun read(json: String?): SavedList {
            val content = json?.let { runCatching { JSONTokener(it).nextValue() }.getOrNull() } as? JSONObject ?: return SavedList()
            fun entries(name: String): List<SavedMessage>? {
                if (content.isNull(name)) return emptyList()
                val array = content.opt(name) as? JSONArray ?: return null
                fun whole(value: Any?) = (value as? Number)?.takeIf { it is Int || it is Long }?.toLong()?.takeIf { it in 0..MAX_TIMESTAMP }
                return List(array.length()) { array.opt(it) as? JSONObject }.mapNotNull { item ->
                    val roomId = item?.opt("room_id") as? String
                    val eventId = item?.opt("event_id") as? String
                    val ts = whole(item?.opt("ts"))
                    if (roomId == null || eventId == null || ts == null || !isMatrixId(roomId, "!") || !isMatrixId(eventId, "$")) null
                    // What an entry adds to the ID and time never costs it its place.
                    else SavedMessage(roomId, eventId, ts, LaterState.entries.firstOrNull { it.key == item.opt("state") } ?: LaterState.IN_PROGRESS,
                        whole(item.opt("remind_at")))
                }
            }
            return normalized(entries("saved") ?: return SavedList(), entries("removed") ?: return SavedList())
        }

        /**
         * One entry per message, the latest; at the same moment saved beats removed, completed beats archived beats in
         * progress, and a later reminder beats an earlier one or none, so a list an older build wrote back can't erase
         * them. Newest first, and no more than each list keeps.
         */
        fun normalized(saved: List<SavedMessage>, removed: List<SavedMessage>): SavedList {
            val rank = compareBy<Pair<SavedMessage, Boolean>>({ it.first.savedAt }, { if (it.second) 1 + it.first.state.ordinal else 0 },
                { it.first.remindAt ?: -1L })
            val latest = HashMap<Pair<String, String>, Pair<SavedMessage, Boolean>>()
            for ((item, isSaved) in saved.map { it to true } + removed.map { it to false }) {
                // Only a message in progress keeps a reminder, and a removal keeps neither.
                val entry = when {
                    !isSaved -> item.copy(state = LaterState.IN_PROGRESS, remindAt = null)
                    item.state != LaterState.IN_PROGRESS -> item.copy(remindAt = null)
                    else -> item
                } to isSaved
                val kept = latest[item.roomId to item.eventId]
                if (kept != null && rank.compare(kept, entry) >= 0) continue
                latest[item.roomId to item.eventId] = entry
            }
            val ordered = latest.values.sortedWith(compareByDescending<Pair<SavedMessage, Boolean>> { it.first.savedAt }
                .thenBy { it.first.roomId }.thenBy { it.first.eventId })
            return SavedList(ordered.filter { it.second }.map { it.first }.take(SAVED_LIMIT),
                ordered.filterNot { it.second }.map { it.first }.take(REMOVED_LIMIT))
        }

        private fun entries(list: List<SavedMessage>) = JSONArray(list.map {
            JSONObject().put("room_id", it.roomId).put("event_id", it.eventId).put("ts", it.savedAt).apply {
                if (it.state != LaterState.IN_PROGRESS) put("state", it.state.key)
                it.remindAt?.let { at -> put("remind_at", at) }
            }
        })
    }
}

/** Swift's Date counts seconds from 2001, so a list written before Later synced keeps savedAt that way. */
private const val SWIFT_EPOCH_MILLIS = 978_307_200_000L

/**
 * An account's Later on this device, so a save or removal made offline outlasts a restart until it reaches the
 * account. It is kept as the account data content is; a list from before Later synced, in the Mac's vault format,
 * still opens.
 */
class SavedMessageStore(context: Context, private val userId: String) {
    private val values = context.getSharedPreferences("saved-messages", Context.MODE_PRIVATE)

    val list: SavedList
        get() {
            val stored = values.getString(userId, null) ?: return SavedList()
            return if (stored.trimStart().startsWith("[")) SavedList.normalized(earlier(stored).orEmpty(), emptyList())
            else SavedList.read(stored)
        }

    fun save(list: SavedList) = values.edit { putString(userId, list.json()) }

    private fun earlier(stored: String): List<SavedMessage>? = runCatching {
        val array = JSONArray(stored)
        List(array.length()) { index ->
            val item = array.getJSONObject(index)
            val savedAt = item.getDouble("savedAt")
            check(savedAt.isFinite())
            SavedMessage(item.getString("roomID"), item.getString("eventID"), SWIFT_EPOCH_MILLIS + Math.round(savedAt * 1_000))
        }
    }.getOrNull()?.takeIf { list ->
        list.size <= SAVED_LIMIT && list.all { isMatrixId(it.roomId, "!") && isMatrixId(it.eventId, "$") } &&
            list.distinctBy { it.roomId to it.eventId }.size == list.size
    }
}

/**
 * Keeps an account's Later in step with its account data, as the Mac does: merges what other devices write as each
 * sync brings it, and writes back whatever this device holds that the account lacks. The list stays in [store] too, so
 * a save or removal made offline outlasts a restart. It writes only over a list it read from the server or heard from
 * a sync, never over the store's, which lags until the first sync; each time [online] comes back it reads the account
 * again, then writes what an earlier attempt couldn't. Runs on [scope], which must be single-threaded, as the app's
 * main scope is; lists are read and written on [work].
 */
class MatrixLater(scope: CoroutineScope, private val client: Client, private val store: SavedMessageStore,
    online: Flow<Boolean>, private val work: CoroutineDispatcher = Dispatchers.Default) : AutoCloseable {
    /** Cancelled on close, so nothing this one started reaches the store after another has taken over. */
    private val own = CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]))
    private val mutableList = MutableStateFlow(store.list)
    val list: StateFlow<SavedList> = mutableList.asStateFlow()
    /** The account's list as last read, heard or written; null until read, so nothing is written over a list unseen. */
    private var published: SavedList? = null
    /** Lists heard from the account, so a write knows whether one landed while it was out. */
    private var heard = 0
    private val changes = Channel<Unit>(Channel.CONFLATED)
    private val handle = client.observeRawAccountDataEvent(SAVED_MESSAGES_TYPE, object : RawAccountDataListener {
        override fun onChange(content: String) {
            val remote = SavedList.read(content)
            own.launch { receive(remote) }
        }
    })

    init {
        // Back online, what the account held before may have changed, so it's read again before any write.
        own.launch {
            online.collect { connected ->
                if (connected) {
                    published = null
                    read()
                }
            }
        }
        // One write at a time; a change while one is out waits for it, and a failed one waits for the next change.
        own.launch {
            for (change in changes) {
                val account = published ?: continue
                val next = list.value
                val before = heard
                val content = withContext(work) { next.content(over = account) } ?: continue
                // A reconnection or a list heard while encoding means the account's list is no longer `account`.
                if (published == null || heard != before) continue
                try {
                    client.setAccountData(SAVED_MESSAGES_TYPE, content)
                    // A list heard meanwhile may have landed after this write, so it stands for the account's.
                    if (heard == before) published = next
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                }
            }
        }
    }

    fun set(roomId: String, eventId: String, saved: Boolean, now: Long = System.currentTimeMillis()) =
        change(list.value.setting(roomId, eventId, saved, now))

    fun set(roomId: String, eventId: String, state: LaterState, now: Long = System.currentTimeMillis()) =
        change(list.value.changing(roomId, eventId, state, now))

    fun remind(roomId: String, eventId: String, remindAt: Long?, now: Long = System.currentTimeMillis()) =
        change(list.value.reminding(roomId, eventId, remindAt, now))

    private fun change(next: SavedList) {
        update(next)
        // Until the account is read nothing is written, so a read that failed must not hold this back.
        if (published == null) read()
    }

    private fun read() {
        own.launch {
            val remote = try {
                client.fetchAccountData(SAVED_MESSAGES_TYPE).let { withContext(work) { SavedList.read(it) } }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                return@launch
            }
            // A sync that answered meanwhile is at least as new.
            if (published == null) receive(remote)
        }
    }

    private fun receive(remote: SavedList) {
        published = remote
        heard++
        update(list.value.merged(remote))
    }

    private fun update(next: SavedList) {
        if (next != list.value) {
            mutableList.value = next
            store.save(next)
        }
        changes.trySend(Unit)
    }

    override fun close() {
        handle.cancel()
        handle.close()
        own.cancel()
    }
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
                    val profile = event.senderProfile as? ProfileDetails.Ready
                    SavedPreview(event.sender, event.senderProfile.nameOf(event.sender),
                        body, event.timestamp.coerceAtMost(Long.MAX_VALUE.toULong()).toLong(), profile?.avatarUrl)
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
    }
}
