package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.MatrixAccount
import ai.nuanu.slatrix.core.SessionStore
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import java.io.File

class AccountViewModel(application: Application) : AndroidViewModel(application) {
    val account = MatrixAccount(viewModelScope, SessionStore(application), File(application.noBackupFilesDir, "matrix"))
    init { account.restore() }
}
