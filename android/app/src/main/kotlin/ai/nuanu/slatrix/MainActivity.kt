package ai.nuanu.slatrix

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import ai.nuanu.slatrix.ui.account.SlatrixApp

class MainActivity : ComponentActivity() {
    private val accountModel: AccountViewModel by viewModels()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { SlatrixApp(accountModel.account) }
    }
}

