package ai.nuanu.slatrix

import android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
import android.view.WindowManager.LayoutParams.SOFT_INPUT_MASK_ADJUST
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KeyboardLayoutTest {
    @Test fun activityRequestsInsetsWithoutPanningTheHeader() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity {
                assertEquals(SOFT_INPUT_ADJUST_RESIZE, it.window.attributes.softInputMode and SOFT_INPUT_MASK_ADJUST)
            }
        }
    }
}
