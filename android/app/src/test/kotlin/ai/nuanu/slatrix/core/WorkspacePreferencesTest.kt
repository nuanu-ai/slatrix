package ai.nuanu.slatrix.core

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class WorkspacePreferencesTest {
    @Test fun aWorkspaceSelectionSurvivesReopeningAndBelongsToItsAccount() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val preferences = WorkspacePreferences(context, "@alex:example.org")
        preferences.selectedSpaceId = "!studio:example.org"
        assertEquals("!studio:example.org", WorkspacePreferences(context, "@alex:example.org").selectedSpaceId)
        assertNull(WorkspacePreferences(context, "@sam:example.org").selectedSpaceId)
        preferences.selectedSpaceId = null
        assertNull(WorkspacePreferences(context, "@alex:example.org").selectedSpaceId)
    }
}
