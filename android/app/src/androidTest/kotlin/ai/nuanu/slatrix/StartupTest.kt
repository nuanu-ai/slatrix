package ai.nuanu.slatrix

import android.app.Activity
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.sdkGitSha

@RunWith(AndroidJUnit4::class)
class StartupTest {
    @Test fun launcherStartsWithNativeBindings() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val launcher = requireNotNull(context.packageManager.getLaunchIntentForPackage(context.packageName))
        ActivityScenario.launch<Activity>(launcher).use { scenario ->
            scenario.onActivity {
                assertTrue("Native SDK revision is unavailable", sdkGitSha().isNotBlank())
            }
        }
    }
}
