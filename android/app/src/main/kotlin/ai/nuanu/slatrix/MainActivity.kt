package ai.nuanu.slatrix

import android.os.Bundle
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
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
            val notification by accountModel.notificationTarget.collectAsState()
            SlatrixApp(accountModel.account, identity, rooms, workspace, notification) { target ->
                accountModel.notificationOpened(target)
                if (intent.getStringExtra(PushNotifications.USER_ID) == target.userId &&
                    intent.getStringExtra(PushNotifications.ROOM_ID) == target.roomId) {
                    intent.removeExtra(PushNotifications.USER_ID)
                    intent.removeExtra(PushNotifications.ROOM_ID)
                }
            }
        }
        consumeCallback(intent)
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
            if (userId != null && roomId != null) accountModel.openNotification(NotificationTarget(userId, roomId))
        }
        intent.data = null
    }
}

