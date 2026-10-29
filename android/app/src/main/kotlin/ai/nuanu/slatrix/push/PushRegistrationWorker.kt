package ai.nuanu.slatrix.push

import android.app.Application
import android.content.Context
import ai.nuanu.slatrix.BuildConfig
import ai.nuanu.slatrix.core.AccountRuntime
import ai.nuanu.slatrix.core.AccountState
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.google.android.gms.tasks.Tasks
import com.google.firebase.messaging.FirebaseMessaging
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

class PushRegistrationWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        if (BuildConfig.PUSH_GATEWAY.isEmpty()) return Result.success()
        return try {
            val completed = withTimeoutOrNull(30_000) {
                val runtime = AccountRuntime.get(applicationContext as Application)
                val account = runtime.account.state.first { it !is AccountState.Connecting } as? AccountState.Connected
                    ?: return@withTimeoutOrNull true
                val registration = PushRegistration(applicationContext)
                val version = registration.tokenVersion
                val token = withContext(Dispatchers.IO) {
                    Tasks.await(FirebaseMessaging.getInstance().token, 15, TimeUnit.SECONDS)
                }
                currentCoroutineContext().ensureActive()
                registration.updateToken(token, expectedVersion = version)
                if ((runtime.account.state.value as? AccountState.Connected)?.client !== account.client) return@withTimeoutOrNull true
                registration.register(account.client, account.userId, BuildConfig.PUSH_GATEWAY)
                true
            } == true
            if (completed) Result.success() else retryOrFail()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            retryOrFail()
        }
    }

    private fun retryOrFail(): Result = if (runAttemptCount < 4) Result.retry() else Result.failure()

    companion object {
        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<PushRegistrationWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork("push-registration", ExistingWorkPolicy.APPEND_OR_REPLACE, request)
        }
    }
}
