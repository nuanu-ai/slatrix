package ai.nuanu.slatrix

import ai.nuanu.slatrix.ui.account.SessionAvatars
import android.app.Application
import android.graphics.Bitmap
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35])
class SessionAvatarsTest {
    // A profile's large photo showed an empty circle first, though the list had the same picture in memory.
    @Test fun aPictureInMemoryAtOneSizeStandsInForAnotherUntilThatLoads() = runTest {
        val avatars = SessionAvatars { _, size ->
            ByteArrayOutputStream().also { Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.PNG, 100, it) }
                .toByteArray()
        }
        avatars.load("mxc://example.org/mira", 48)
        assertEquals(48, avatars.cached("mxc://example.org/mira", 240)?.width)
        assertEquals(240, avatars.load("mxc://example.org/mira", 240)?.width)
        assertEquals(240, avatars.cached("mxc://example.org/mira", 240)?.width)
        assertNull(avatars.cached("mxc://example.org/sam", 240))
    }
}
