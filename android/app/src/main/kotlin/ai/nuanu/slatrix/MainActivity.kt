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

class MainActivity : ComponentActivity() {
    private val accountModel: AccountViewModel by viewModels()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val identity by accountModel.identity.collectAsState()
            val rooms by accountModel.rooms.collectAsState()
            val workspace by accountModel.workspace.collectAsState()
            SlatrixApp(accountModel.account, identity, rooms, workspace)
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
        intent.data = null
    }
}

