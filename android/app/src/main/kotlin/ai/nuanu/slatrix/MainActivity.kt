package ai.nuanu.slatrix

import android.os.Bundle
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import ai.nuanu.slatrix.core.MatrixWorkspace
import ai.nuanu.slatrix.ui.account.SlatrixApp
import ai.nuanu.slatrix.push.NotificationTarget
import ai.nuanu.slatrix.push.PushNotifications

class MainActivity : ComponentActivity() {
    private val accountModel: AccountViewModel by viewModels()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val identity by accountModel.identity.collectAsState()
            val rooms by accountModel.rooms.collectAsState()
            val workspace by accountModel.workspace.collectAsState()
            val threads by accountModel.threads.collectAsState()
            val activity by accountModel.activity.collectAsState()
            val search by accountModel.search.collectAsState()
            val people by accountModel.people.collectAsState()
            val notification by accountModel.notificationTarget.collectAsState()
            SlatrixApp(accountModel.account, identity, rooms, workspace, notification, threads, activity, search, people) { target ->
                accountModel.notificationHandled(target)
                if (intent.getStringExtra(PushNotifications.USER_ID) == target.userId &&
                    intent.getStringExtra(PushNotifications.ROOM_ID) == target.roomId) {
                    intent.removeExtra(PushNotifications.USER_ID)
                    intent.removeExtra(PushNotifications.ROOM_ID)
                    intent.removeExtra(PushNotifications.THREAD_ID)
                }
            }
        }
        consumeCallback(intent)
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                try {
                    activeOpenTarget(accountModel.workspace, accountModel.threads).collect { target ->
                        PushNotifications.openRoom = target?.first
                        PushNotifications.openThread = target?.second
                    }
                } finally {
                    PushNotifications.openRoom = null
                    PushNotifications.openThread = null
                }
            }
        }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        consumeCallback(intent)
        setIntent(intent)
    }

    private fun consumeCallback(intent: Intent) {
        if (intent.action == Intent.ACTION_VIEW) intent.dataString?.let(accountModel.account::handleCallback)
        if (intent.action == "$packageName.OPEN_NOTIFICATION") {
            val userId = intent.getStringExtra(PushNotifications.USER_ID)
            val roomId = intent.getStringExtra(PushNotifications.ROOM_ID)
            val eventId = intent.getStringExtra(PushNotifications.EVENT_ID)
            // The launcher activity is exported, so only a notification this app posted may open a room.
            if (userId != null && roomId != null && eventId != null && PushNotifications(this).delivered(userId, roomId, eventId)) {
                val thread = intent.getStringExtra(PushNotifications.THREAD_ID)?.takeIf { it.startsWith('$') }
                accountModel.openNotification(NotificationTarget(userId, roomId, eventId, thread))
            }
        }
        intent.data = null
    }
}

/** The room (and optional thread) currently on screen, preferring an active thread over the channel under it. */
@OptIn(ExperimentalCoroutinesApi::class)
internal fun activeOpenTarget(workspace: StateFlow<MatrixWorkspace?>, threads: StateFlow<MatrixWorkspace?>): Flow<Pair<String, String?>?> =
    combine(workspace, threads) { main, thread -> main to thread }.flatMapLatest { (main, thread) ->
        combine(main?.selected ?: flowOf(null), thread?.selected ?: flowOf(null)) { channel, activeThread ->
            activeThread?.let { it.room.id to it.threadRoot } ?: channel?.let { it.room.id to null }
        }
    }

