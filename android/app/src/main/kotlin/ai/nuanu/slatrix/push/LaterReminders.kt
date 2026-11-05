package ai.nuanu.slatrix.push

import ai.nuanu.slatrix.core.SavedList
import ai.nuanu.slatrix.core.SavedMessage
import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.await
import androidx.work.workDataOf
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.first

/**
 * Keeps WorkManager's queue to Later's reminders still to come for the account signed in, so each notifies at its time
 * even after a restart. A reminder another device sets is queued here too; one already due when this device learns of
 * it isn't, so it never notifies twice.
 */
class LaterReminders(context: Context) {
    private val work = WorkManager.getInstance(context)

    /**
     * Queues what [list] has still to come for [userId] and withdraws everything else queued; a null account, as when
     * signed out, withdraws all. [describe] gives a reminder's title and text.
     */
    suspend fun sync(userId: String?, list: SavedList, now: Long = System.currentTimeMillis(),
        describe: suspend (SavedMessage) -> Pair<String, String>) {
        val wanted = userId?.let { user -> list.reminders(now).associateBy { name(user, it) } }.orEmpty()
        val queued = work.getWorkInfosByTagFlow(TAG).first().filterNot { it.state.isFinished }
            .flatMap { it.tags }.filter { it.startsWith(PREFIX) }.toSet()
        for (name in queued - wanted.keys) work.cancelUniqueWork(name).await()
        for ((name, item) in wanted) if (name !in queued) {
            val (title, text) = describe(item)
            work.enqueueUniqueWork(name, ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<LaterReminderWorker>()
                .setInitialDelay((item.remindAt ?: now) - now, TimeUnit.MILLISECONDS).addTag(TAG).addTag(name)
                .setInputData(workDataOf("user_id" to userId, "room_id" to item.roomId, "event_id" to item.eventId,
                    "title" to title, "text" to text)).build()).await()
        }
    }

    private fun name(userId: String, item: SavedMessage) =
        "$PREFIX${userId.length}:$userId${item.roomId.length}:${item.roomId}${item.eventId}@${item.remindAt}"

    companion object {
        const val TAG = "ai.nuanu.slatrix.push.LaterReminder"
        private const val PREFIX = "later:"
    }
}

class LaterReminderWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val data = inputData
        PushNotifications(applicationContext).remind(data.getString("user_id") ?: return Result.failure(),
            data.getString("room_id") ?: return Result.failure(), data.getString("event_id") ?: return Result.failure(),
            data.getString("title").orEmpty(), data.getString("text").orEmpty())
        return Result.success()
    }
}
