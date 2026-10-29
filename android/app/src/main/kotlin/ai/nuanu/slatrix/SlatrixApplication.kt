package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.AccountRuntime
import ai.nuanu.slatrix.core.AppearancePreferences
import org.matrix.rustcomponents.sdk.LogLevel
import org.matrix.rustcomponents.sdk.TracingConfiguration
import org.matrix.rustcomponents.sdk.initPlatform
import org.matrix.rustsdk.Android

class SlatrixApplication : Application() {
    val runtime get() = AccountRuntime.get(this)

    override fun onCreate() {
        super.onCreate()
        // A choice saved before the system kept it would otherwise start the app in the system's mode.
        AppearancePreferences(this).applyNightMode()
        Android.init(applicationContext)
        initPlatform(
            config = TracingConfiguration(
                logLevel = LogLevel.WARN,
                traceLogPacks = emptyList(),
                extraTargets = emptyList(),
                writeToStdoutOrSystem = true,
                writeToFiles = null,
                sentryConfig = null,
            ),
            useLightweightTokioRuntime = false,
        )
    }
}
