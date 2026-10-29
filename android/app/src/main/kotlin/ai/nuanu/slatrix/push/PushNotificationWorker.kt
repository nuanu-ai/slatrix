package ai.nuanu.slatrix.push

import android.app.Application
import android.content.Context
import android.os.Build
import ai.nuanu.slatrix.BuildConfig
import ai.nuanu.slatrix.core.AccountRuntime
import ai.nuanu.slatrix.core.AccountState
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import org.matrix.rustcomponents.sdk.NotificationStatus

class PushNotificationWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val notifications = PushNotifications(applicationContext)
        if (BuildConfig.PUSH_GATEWAY.isEmpty() || !notifications.enabled) return Result.success()
        val roomId = inputData.getString("room_id") ?: return Result.failure()
        val eventId = inputData.getString("event_id") ?: return Result.failure()
        return try {
            val completed = withTimeoutOrNull(30_000) {
                val runtime = AccountRuntime.get(applicationContext as Application)
                val account = runtime.account.state.first { it !is AccountState.Connecting } as? AccountState.Connected
                    ?: return@withTimeoutOrNull true
                val rooms = runtime.rooms.filterNotNull().first { it.client === account.client }
                var status: NotificationStatus? = null
                try {
                    status = try {
                        rooms.notification(roomId, eventId)
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        null
                    }
                    if ((runtime.account.state.value as? AccountState.Connected)?.client === account.client) {
                        val preview = if (status is NotificationStatus.Event &&
                            runtime.identity.value?.state?.value?.requiresVerification != false) null else status
                        notifications.show(account.userId, roomId, eventId, preview)
                    }
                } finally {
                    status?.destroy()
                }
                true
            } == true
            if (completed) Result.success() else retryOrFail()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            retryOrFail()
        }
    }

    private fun retryOrFail(): Result = if (runAttemptCount < 2) Result.retry() else Result.failure()

    companion object {
        fun enqueue(context: Context, roomId: String, eventId: String, highPriority: Boolean) {
            val request = OneTimeWorkRequestBuilder<PushNotificationWorker>()
                .setInputData(workDataOf("room_id" to roomId, "event_id" to eventId))
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            if (Build.VERSION.SDK_INT >= 31 && highPriority) request.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            WorkManager.getInstance(context).enqueueUniqueWork("push-${pushKey("", roomId, eventId)}", ExistingWorkPolicy.KEEP, request.build())
        }
    }
}
