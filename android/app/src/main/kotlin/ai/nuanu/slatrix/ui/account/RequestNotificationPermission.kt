package ai.nuanu.slatrix.ui.account

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.core.content.edit

@Composable
fun RequestNotificationPermission(signedIn: Boolean, configured: Boolean) {
    if (!configured || Build.VERSION.SDK_INT < 33) return
    val context = LocalContext.current
    val preferences = remember(context) { context.getSharedPreferences("notification-permission", Context.MODE_PRIVATE) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    LaunchedEffect(signedIn) {
        if (!signedIn || preferences.getBoolean("requested", false) ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return@LaunchedEffect
        launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
        preferences.edit { putBoolean("requested", true) }
    }
}
