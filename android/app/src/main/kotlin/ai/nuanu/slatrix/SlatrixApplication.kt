package ai.nuanu.slatrix

import android.app.Application
import org.matrix.rustcomponents.sdk.LogLevel
import org.matrix.rustcomponents.sdk.TracingConfiguration
import org.matrix.rustcomponents.sdk.initPlatform
import org.matrix.rustsdk.Android

class SlatrixApplication : Application() {
    override fun onCreate() {
        super.onCreate()
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
